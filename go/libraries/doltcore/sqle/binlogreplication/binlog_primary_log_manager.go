// Copyright 2024 Dolthub, Inc.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

package binlogreplication

import (
	"encoding/binary"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/dolthub/vitess/go/mysql"
	"github.com/sirupsen/logrus"

	"github.com/dolthub/dolt/go/libraries/utils/filesys"
	"github.com/dolthub/go-mysql-server/sql"
	gmstypes "github.com/dolthub/go-mysql-server/sql/types"
)

var binlogDirectory = filepath.Join(".dolt", "binlog")

// binlogFileMagicNumber holds the four bytes that start off every
// MySQL binlog file and identify the file as a MySQL binlog.
var binlogFileMagicNumber = []byte{0xfe, 0x62, 0x69, 0x6e}

type LogManager struct {
	currentBinlogFile     *os.File
	currentBinlogFileName string
	currentPosition       int
	fs                    filesys.Filesys
	binlogFormat          mysql.BinlogFormat
	binlogEventMeta       mysql.BinlogEventMetadata
}

// NewLogManager creates a new LogManager instance where binlog files are stored in the .dolt/binlog directory
// underneath the specified |fs| filesystem. The |binlogFormat| and |binlogStream| are used to initialize the
// new binlog file.
func NewLogManager(fs filesys.Filesys, binlogFormat mysql.BinlogFormat, binlogEventMeta mysql.BinlogEventMetadata) *LogManager {
	// TODO: On server startup, we need to find the most recent binlog file, add a rotate event at the end (if necessary?), and start a new file. Documentation seems to indicate that a rotate event is added at the end of a binlog file, so that the streamer can jump to the next file, but I don't see this in our MySQL sample binlog files. Need to do more testing here.

	lm := &LogManager{
		fs:              fs,
		binlogFormat:    binlogFormat,
		binlogEventMeta: binlogEventMeta,
	}

	// TODO: Could resolve the base dir for the binlog file directory here; would it help us avoid returning errors in other APIs?

	// Initialize binlog file storage (extract to function!)
	err := fs.MkDirs(binlogDirectory)
	if err != nil {
		panic(err)
	}

	// Initialize current binlog file
	nextLogFilename, err := lm.nextLogFile()
	if err != nil {
		panic(err)
	}
	lm.currentBinlogFileName = nextLogFilename

	// Ugh... we need binlogFormat and binlogEventMeta in order to do this...
	// Actually... Do we need binlogEventMeta, or could we fake it? We only need binlogEventMeta so that
	// Vitess can call a function on that instance, and for the server Id. The position in the file
	// should always be zero at this point, so maybe we could clean this up more?
	err = lm.initializeCurrentLogFile(binlogFormat, binlogEventMeta)
	if err != nil {
		panic(err)
	}

	return lm
}

func (lm *LogManager) nextLogFile() (filename string, err error) {
	mostRecentLogfile, err := lm.mostRecentLogFileForBranch(BinlogBranch)
	if err != nil {
		return "", err
	}

	if mostRecentLogfile == "" {
		return formatBinlogFilename(BinlogBranch, 1), nil
	} else {
		branch, sequence, err := parseBinlogFilename(mostRecentLogfile)
		if err != nil {
			return "", err
		}
		return formatBinlogFilename(branch, sequence+1), nil
	}
}

func (lm *LogManager) logFilesOnDisk() (files []string, err error) {
	err = lm.fs.Iter(binlogDirectory, false, func(path string, size int64, isDir bool) (stop bool) {
		base := filepath.Base(path)
		if strings.HasPrefix(base, "binlog-") {
			files = append(files, base)
		}

		return false
	})
	if err != nil {
		return nil, err
	}

	return files, nil
}

func (lm *LogManager) logFilesOnDiskForBranch(branch string) (files []string, err error) {
	branch = strings.ToLower(branch)
	err = lm.fs.Iter(binlogDirectory, false, func(path string, size int64, isDir bool) (stop bool) {
		base := filepath.Base(path)
		if strings.HasPrefix(base, "binlog-"+branch) {
			files = append(files, base)
		}

		return false
	})
	if err != nil {
		return nil, err
	}

	return files, nil
}

func (lm *LogManager) mostRecentLogfile() (logFile string, err error) {
	logFiles, err := lm.logFilesOnDisk()
	if err != nil {
		return "", err
	}

	return logFiles[len(logFiles)-1], nil
}

func (lm *LogManager) mostRecentLogFileForBranch(branch string) (logFile string, err error) {
	logFiles, err := lm.logFilesOnDiskForBranch(branch)
	if err != nil {
		return "", err
	}

	// TODO: This assumes the list comes back sorted by time or by filename
	if len(logFiles) == 0 {
		return "", nil
	} else {
		return logFiles[len(logFiles)-1], nil
	}
}

// RotateLogFile rotates the current log file that is actively being written to. A new binlog file is created and
// initialized, including writing the first four bytes with the binlog magic number, and the old binlog file is closed.
// Rotation should occur when an administrator explicitly requests it with the `FLUSH LOGS` statement, during server
// shutdown or restart, or when the current binary log file size exceeds the maximum size defined by the
// @@max_binlog_size system variable.
func (lm *LogManager) RotateLogFile() error {
	nextLogFile, err := lm.nextLogFile()
	if err != nil {
		return err
	}
	logrus.Tracef("Rotating bin log file to: %s", nextLogFile)

	binlogEvent := mysql.NewRotateEvent(lm.binlogFormat, lm.binlogEventMeta, 0, nextLogFile, 0)
	if err = lm.WriteEvents(binlogEvent); err != nil {
		return err
	}

	// TODO: There is some synchronization needed here, too... we need a lock on the log file so that no other
	//      threads write after we write the rotate event.
	//      The writer has got to be a singleton right, we can't have multiple threads sharing a single log file.
	//      We're running over a channel, so that solves it

	// Close the current binlog file
	if err = lm.currentBinlogFile.Close(); err != nil {
		logrus.Errorf("error closing current binlog file before rotating to new file: %s", err.Error())
	}

	// Open and initialize a new binlog file
	lm.currentBinlogFileName = nextLogFile
	return lm.initializeCurrentLogFile(lm.binlogFormat, lm.binlogEventMeta)
}

func (lm *LogManager) PurgeLogFiles() error {
	// TODO: implement support for purging older binlog files
	//       This also requires setting gtid_purged
	// https://dev.mysql.com/doc/refman/8.0/en/replication-options-gtids.html#sysvar_gtid_purged
	// Need to test the case where the GTID requested is not
	// available –has been executed, but has been purged
	return nil
}

func (lm *LogManager) initializeCurrentLogFile(binlogFormat mysql.BinlogFormat, binlogEventMeta mysql.BinlogEventMetadata) error {
	logrus.Tracef("Initializing binlog file: %s", lm.currentBinlogFilepath())

	// Open the file in append mode
	file, err := os.OpenFile(lm.currentBinlogFilepath(), os.O_APPEND|os.O_CREATE|os.O_WRONLY, 0644)
	if err != nil {
		return err
	}
	lm.currentBinlogFile = file
	lm.currentPosition = 0

	// Write Magic Number
	_, err = file.Write(binlogFileMagicNumber)
	if err != nil {
		return err
	}
	lm.currentPosition += len(binlogFileMagicNumber)

	// Write Format Event – FormatDescription should be the first event in each binlog file
	binlogEvent := mysql.NewFormatDescriptionEvent(binlogFormat, binlogEventMeta)
	binlogEventMeta.NextLogPosition += binlogEvent.Length()
	if err = lm.WriteEvents(binlogEvent); err != nil {
		return err
	}

	// TODO: Write PreviousGtids event
	//previousGtidSet := make(mysql.Mysql56GTIDSet)
	//return lm.WriteEvents(mysql.NewPreviousGTIDsEvent(binlogFormat, binlogStream, previousGtidSet))

	return nil
}

// lookupMaxBinlogSize looks up the value of the @@max_binlog_size system variable and returns it, along with any
// errors encountered while looking it up.
func lookupMaxBinlogSize() (int, error) {
	_, value, ok := sql.SystemVariables.GetGlobal("max_binlog_size")
	if !ok {
		return 0, fmt.Errorf("system variable @@max_binlog_size not found")
	}

	intValue, _, err := gmstypes.Int32.Convert(value)
	if err != nil {
		return 0, err
	}
	return int(intValue.(int32)), nil
}

// WriteEvents writes |binlogEvents| to the current binlog file.
func (lm *LogManager) WriteEvents(binlogEvents ...mysql.BinlogEvent) error {
	maxBinlogSize, err := lookupMaxBinlogSize()
	if err != nil {
		return err
	}

	// Write to the file
	rotateLogFile := false
	for _, event := range binlogEvents {
		// NOTE: When we write the event to file, we need to ensure the next log position field
		// is correct. That means we have to serialize the events going into the log file and
		// we update their NextLogPosition field in the header to ensure it's correct. Because
		// we change the packet, we must recompute the checksum.
		// TODO: This means we can get rid of the position tracking code in the binlog producer type
		nextPosition := lm.currentPosition + len(event.Bytes())
		binary.LittleEndian.PutUint32(event.Bytes()[13:13+4], uint32(nextPosition))
		mysql.RecomputeChecksum(lm.binlogFormat, event.Bytes())

		lm.currentPosition = nextPosition
		if nextPosition > maxBinlogSize && !event.IsRotate() {
			rotateLogFile = true
		}

		// Write the event to file
		if _, err := lm.currentBinlogFile.Write(event.Bytes()); err != nil {
			return err
		}
	}

	if rotateLogFile {
		// NOTE: Rotate event should be the very last entry in the (completed) binlog file.
		//       Streamers will read the rotate event and know what file to open next.
		return lm.RotateLogFile()
	}

	return nil
}

func (lm *LogManager) resolveLogFile(filename string) (string, error) {
	binlogBaseDir, err := lm.fs.Abs(binlogDirectory)
	if err != nil {
		return "", err
	}

	// TODO: Should we make sure it exists?
	return filepath.Join(binlogBaseDir, filename), nil
}

func (lm *LogManager) currentBinlogFilepath() string {
	logFile, err := lm.resolveLogFile(lm.currentBinlogFileName)
	if err != nil {
		// TODO: return an error, or handle this err somewhere else where we do return an error
		panic(err)
	}

	return logFile
}

// formatBinlogFilename formats a binlog filename using the specified |branch| and |sequence| number. The
// returned filename will be of the form "binlog-main.000001".
func formatBinlogFilename(branch string, sequence int) string {
	return fmt.Sprintf("binlog-%s.%06d", branch, sequence)
}

// parseBinlogFilename parses a binlog filename, of the form "binlog-main.000001", into its branch and
// sequence number.
func parseBinlogFilename(filename string) (branch string, sequence int, err error) {
	if !strings.HasPrefix(filename, "binlog-") {
		return "", 0, fmt.Errorf("invalid binlog filename: %s; must start with 'binlog-'", filename)
	}

	filename = strings.TrimPrefix(filename, "binlog-")

	splits := strings.Split(filename, ".")
	if len(splits) != 2 {
		return "", 0, fmt.Errorf(
			"unable to parse binlog filename: %s; expected format 'binlog-branch.sequence'", filename)
	}

	branch = splits[0]
	sequenceString := splits[1]

	sequence, err = strconv.Atoi(sequenceString)
	if err != nil {
		return "", 0, fmt.Errorf(
			"unable to parse binlog sequence number: %s; %s", sequenceString, err.Error())
	}

	return branch, sequence, nil
}
