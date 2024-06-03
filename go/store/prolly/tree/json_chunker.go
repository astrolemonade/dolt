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

package tree

import (
	"bytes"
	"context"
	"fmt"
	"github.com/dolthub/dolt/go/store/prolly/message"
	"github.com/dolthub/go-mysql-server/sql"
	"github.com/dolthub/go-mysql-server/sql/types"
	"io"
)

// JsonChunker writes a prolly tree containing a JSON document.
// The tree generated by a JsonChunker uses different message types for leaf and non-leaf nodes:
//   - Leaf nodes are Blobs. Each leaf node contains a single value, which is a segment of the document. Each segment ends
//     on a valid jsonLocation
//   - Non-leaf nodes are AddressMaps. Each key is a jsonLocation corresponding to the end of the span represented by the child node.
//
// This class handles the writing of the level 0 nodes (the blobs). Note this means that the |chunker| field, which
// contains the chunker for the AddressMap nodes, begins at level 1.
type JsonChunker struct {
	jCur     *JsonCursor
	jScanner *JsonScanner
	chunker  *chunker[message.AddressMapSerializer]
	ns       NodeStore
}

// SerializeJsonToAddr stores a JSON document as a prolly tree, returning the root of the tree.
func SerializeJsonToAddr(ctx context.Context, ns NodeStore, j sql.JSONWrapper) (Node, error) {
	if indexedJson, ok := j.(IndexedJsonDocument); ok {
		return indexedJson.m.Root, nil
	}
	jsonBytes, err := types.MarshallJson(j)
	if err != nil {
		return Node{}, err
	}

	jsonChunker, err := newEmptyJsonChunker(ctx, ns)
	if err != nil {
		return Node{}, err
	}
	jsonChunker.appendJsonToBuffer(jsonBytes)
	jsonChunker.processBuffer(ctx)

	node, err := jsonChunker.Done(ctx)
	if err != nil {
		return Node{}, err
	}
	return node, nil
}

// newEmptyJsonChunker creates a new JsonChunker without a corresponding JsonCursor. This is used when writing
// a new IndexedJsonDocument that not based on an existing IndexedJsonDocument.
func newEmptyJsonChunker(ctx context.Context, ns NodeStore) (*JsonChunker, error) {
	newChunkerFn := newChunker[message.AddressMapSerializer]
	chunker, err := newChunkerFn(ctx, nil, 1, ns, message.NewAddressMapSerializer(ns.Pool()))
	if err != nil {
		return nil, err
	}
	scanner := ScanJsonFromBeginning(nil)
	jChunker := JsonChunker{
		jCur:     nil,
		jScanner: &scanner,
		chunker:  chunker,
		ns:       ns,
	}
	return &jChunker, err
}

// newJsonChunker creates a new JsonChunker based on an existing IndexedJsonDocument.
// |jCur| is a cursor into the existing document, pointing to the location of the first change.
// |nextKey| is the location in the document of the next value to be written.
func newJsonChunker(ctx context.Context, jCur *JsonCursor, ns NodeStore) (*JsonChunker, error) {
	newChunkerFn := newChunker[message.AddressMapSerializer]
	chunker, err := newChunkerFn(ctx, jCur.cur.parent, 1, ns, message.NewAddressMapSerializer(ns.Pool()))
	if err != nil {
		return nil, err
	}

	// Copy the original bytes so that the JsonChunker's buffer doesn't point into JsonCursor's buffer.
	initialBytes := bytes.Clone(jCur.jsonScanner.jsonBuffer[:jCur.jsonScanner.valueOffset])
	scanner := JsonScanner{
		jsonBuffer:  initialBytes,
		currentPath: jCur.jsonScanner.currentPath.Clone(),
		valueOffset: len(initialBytes),
	}

	jChunker := JsonChunker{
		jCur:     jCur,
		jScanner: &scanner,
		chunker:  chunker,
		ns:       ns,
	}

	return &jChunker, nil
}

// writeKey adds a new key to end of the JsonChunker's buffer. If required, it also adds a comma before the key.
// If the path points to an array, no key will be written, but the comma will still be written if required.
func (j *JsonChunker) writeKey(keyPath jsonLocation) {
	finalPathElement, isArray := keyPath.getLastPathElement()

	isFirstValue := j.jScanner.firstElementOrEndOfEmptyValue()

	if !isFirstValue {
		j.appendJsonWithoutSplitting([]byte{','})
	}
	if !isArray {
		j.appendJsonWithoutSplitting([]byte(fmt.Sprintf(`"%s":`, finalPathElement)))
	}
}

func (j *JsonChunker) Done(ctx context.Context) (Node, error) {
	var endOfDocumentKey = []byte{byte(endOfValue)}

	if j.jCur == nil {
		// The remaining buffer becomes the final blob
		err := j.createNewLeafChunk(ctx, endOfDocumentKey, j.jScanner.jsonBuffer)
		if err != nil {
			return Node{}, err
		}
		return j.chunker.Done(ctx)
	}
	cur := j.jCur.cur
	cursorDecoder := j.jCur.jsonScanner
	jsonBytes := cursorDecoder.jsonBuffer[cursorDecoder.valueOffset:]
	// When inserting into the beginning of an object or array, we need to add an extra comma.
	// We could track then in the chunker, but it's easier to just check the next part of JSON to determine
	// whether we need the comma.
	if jsonBytes[0] != '}' && jsonBytes[0] != ']' && jsonBytes[0] != ',' {
		j.appendJsonToBuffer([]byte(","))
	}
	// Append the rest of the JsonCursor, then continue until we either exhaust the cursor, or we coincide with a boundary from the original tree.
	for {
		j.appendJsonToBuffer(jsonBytes)
		j.processBuffer(ctx)
		if j.jScanner.jsonBuffer == nil {
			// Advance the cursor so that we don't re-insert the current key when finalizing the chunker.
			j.jCur.cur.advance(ctx)
			return j.chunker.Done(ctx)
		}
		err := cur.advance(ctx)
		if err != nil {
			return Node{}, err
		}
		if !cur.Valid() {
			// We reached the end of the tree.
			err := j.createNewLeafChunk(ctx, endOfDocumentKey, j.jScanner.jsonBuffer)
			if err != nil {
				return Node{}, err
			}
			return j.chunker.Done(ctx)
		}
		jsonBytes = cur.currentValue()
	}
}

// createNewLeafChunk writes a new Blob to the nodestore, and updates the parent chunker.
// Do not call this method directly. It should only get called from within this file.
func (j *JsonChunker) createNewLeafChunk(ctx context.Context, key, value []byte) error {
	blobSerializer := message.NewBlobSerializer(j.ns.Pool())
	msg := blobSerializer.Serialize(nil, [][]byte{value}, []uint64{1}, 0)
	node, err := NodeFromBytes(msg)
	if err != nil {
		return err
	}
	addr, err := j.ns.Write(ctx, node)
	if err != nil {
		return err
	}
	// Copy the key when adding it to the chunker.
	return j.chunker.AddPair(ctx, bytes.Clone(key), addr[:])
}

// appendJsonWithoutSplitting writes JSON to the buffer, but prevents the new JSON from later being scanned for chunk boundaries.
// This is useful in situations where we know that crossing a boundary is not possible and know what the resulting scanner state will be.
// Do not call this method directly. It should only get called from within this file.
func (j *JsonChunker) appendJsonWithoutSplitting(jsonBytes []byte) {
	j.appendJsonToBuffer(jsonBytes)
	j.jScanner.skipBytes(len(jsonBytes))
}

// appendJsonToBuffer writes JSON to the buffer, which will be checked for chunk boundaries the next time processBuffer is called.
// Do not call this method directly. It should only get called from within this file.
func (j *JsonChunker) appendJsonToBuffer(jsonBytes []byte) {
	if j.jScanner.jsonBuffer == nil {
		j.jScanner.jsonBuffer = jsonBytes
	} else {
		j.jScanner.jsonBuffer = append(j.jScanner.jsonBuffer, jsonBytes...)
	}
}

// processBuffer reads all new additions added by appendJsonToBuffer, and determines any new chunk boundaries.
// Do not call this method directly. It should only get called from within this file.
func (j *JsonChunker) processBuffer(ctx context.Context) error {
	for j.jScanner.AdvanceToNextLocation() != io.EOF {
		key := j.jScanner.currentPath.key
		value := j.jScanner.jsonBuffer[:j.jScanner.valueOffset]
		if crossesBoundary(key, value) {
			err := j.createNewLeafChunk(ctx, key, value)
			if err != nil {
				return err
			}
			var newBuffer []byte
			if !j.jScanner.atEndOfChunk() {
				newBuffer = j.jScanner.jsonBuffer[j.jScanner.valueOffset:]
			}
			newScanner := ScanJsonFromMiddle(newBuffer, j.jScanner.currentPath)
			j.jScanner = &newScanner
		}
	}
	return nil
}

// crossesBoundary calculates whether a JSON segment, ending at a specific jsonLocation
func crossesBoundary(key jsonLocationKey, buf []byte) bool {
	salt := levelSalt[0]
	thisSize := uint32(len(buf))

	if thisSize < minChunkSize {
		return false
	}
	if thisSize > maxChunkSize {
		return true
	}

	h := xxHash32(key, salt)
	return weibullCheck(thisSize, thisSize, h)
}
