#!/usr/bin/env bats
load $BATS_TEST_DIRNAME/helper/common.bash

setup() {
    setup_common

    cat <<SQL > 1pk5col-ints-sch.sql
CREATE TABLE test (
  pk BIGINT NOT NULL COMMENT 'tag:0',
  c1 BIGINT COMMENT 'tag:1',
  c2 BIGINT COMMENT 'tag:2',
  c3 BIGINT COMMENT 'tag:3',
  c4 BIGINT COMMENT 'tag:4',
  c5 BIGINT COMMENT 'tag:5',
  PRIMARY KEY (pk)
);
SQL

    cat <<SQL > 1pk1col-char-sch.sql
CREATE TABLE test (
  pk BIGINT NOT NULL COMMENT 'tag:0',
  c CHAR(5) COMMENT 'tag:1',
  PRIMARY KEY (pk)
);
SQL

    cat <<DELIM > 1pk5col-ints.csv
pk,c1,c2,c3,c4,c5
0,1,2,3,4,5
1,1,2,3,4,5
DELIM

    cat <<SQL > employees-sch.sql
CREATE TABLE employees (
  \`id\` LONGTEXT NOT NULL COMMENT 'tag:0',
  \`first name\` LONGTEXT COMMENT 'tag:1',
  \`last name\` LONGTEXT COMMENT 'tag:2',
  \`title\` LONGTEXT COMMENT 'tag:3',
  \`start date\` LONGTEXT COMMENT 'tag:4',
  \`end date\` LONGTEXT COMMENT 'tag:5',
  PRIMARY KEY (id)
);
SQL

}

teardown() {
    assert_feature_version
    teardown_common
}

@test "import-update-tables: update table using csv" {
    dolt sql < 1pk5col-ints-sch.sql
    run dolt table import -u test `batshelper 1pk5col-ints.csv`
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Rows Processed: 2, Additions: 2, Modifications: 0, Had No Effect: 0" ]] || false
    [[ "$output" =~ "Import completed successfully." ]] || false

    # Validate that a successful import with no bad rows does not print the following
    ! [[ "$output" =~ "The following rows were skipped:" ]] || false
}

@test "import-update-tables: update table using csv with null (blank) values" {
    skip "nulls from csv not working correctly on update"
    dolt sql < 1pk5col-ints-sch.sql
    run dolt table import -u test `batshelper 1pk5col-nulls.csv`
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Import completed successfully." ]] || false

    # Validate that a successful import with no bad rows does not print the following
    ! [[ "$output" =~ "The following rows were skipped:" ]] || false
}

@test "import-update-tables: update table using schema with csv" {
    dolt sql < 1pk5col-ints-sch.sql
    run dolt table import -u -s `batshelper 1pk5col-ints-schema.json` test `batshelper 1pk5col-ints.csv`
    [ "$status" -eq 1 ]
    [[ "$output" =~ "fatal: schema is not supported for update or replace operations" ]] || false
}

@test "import-update-tables: update table using csv with newlines" {
    dolt sql <<SQL
CREATE TABLE test (
  pk LONGTEXT NOT NULL COMMENT 'tag:0',
  c1 LONGTEXT COMMENT 'tag:1',
  c2 LONGTEXT COMMENT 'tag:2',
  c3 LONGTEXT COMMENT 'tag:3',
  c4 LONGTEXT COMMENT 'tag:4',
  c5 LONGTEXT COMMENT 'tag:5',
  PRIMARY KEY (pk)
);
SQL
    run dolt table import -u test `batshelper 1pk5col-strings-newlines.csv`
    [ "$status" -eq 0 ]
}

@test "import-update-tables: update table using json" {
    dolt sql < employees-sch.sql
    run dolt table import -u employees `batshelper employees-tbl.json`
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Rows Processed: 3, Additions: 3, Modifications: 0, Had No Effect: 0" ]] || false
    [[ "$output" =~ "Import completed successfully." ]] || false
}

@test "import-update-tables: update table using wrong json" {
    dolt sql <<SQL
CREATE TABLE employees (
  \`idz\` LONGTEXT NOT NULL COMMENT 'tag:0',
  \`first namez\` LONGTEXT COMMENT 'tag:1',
  \`last namez\` LONGTEXT COMMENT 'tag:2',
  \`titlez\` LONGTEXT COMMENT 'tag:3',
  \`start datez\` LONGTEXT COMMENT 'tag:4',
  \`end datez\` LONGTEXT COMMENT 'tag:5',
  PRIMARY KEY (idz)
);
SQL
    run dolt table import -u employees `batshelper employees-tbl.json`
    [ "$status" -eq 1 ]
    [[ "$output" =~ "not found in schema" ]] || false
}

@test "import-update-tables: update table using schema with json" {
    dolt sql < employees-sch.sql
    run dolt table import -u -s employees-sch.sql employees `batshelper employees-tbl.json`
    [ "$status" -eq 1 ]
    [[ "$output" =~ "fatal: schema is not supported for update or replace operations" ]] || false
}

@test "import-update-tables: update table with existing imported data with different schema" {
  run dolt table import -c -s employees-sch.sql employees `batshelper employees-tbl.json`
  [ "$status" -eq 0 ]
  [[ "$output" =~ "Import completed successfully." ]] || false
  run dolt table import -u employees `batshelper employees-tbl-schema-wrong.json`
  [ "$status" -eq 1 ]
  [[ "$output" =~ "not found in schema" ]] || false
}

@test "import-update-tables: update table with json when table does not exist" {
    run dolt table import -u employees `batshelper employees-tbl.json`
    [ "$status" -eq 1 ]
    [[ "$output" =~ "The following table could not be found:" ]] || false
}

@test "import-update-tables: update table with a json with columns in different order" {
    dolt sql <<SQL
CREATE TABLE employees (
  \`id\` LONGTEXT NOT NULL COMMENT 'tag:0',
  \`first name\` LONGTEXT COMMENT 'tag:1',
  \`last name\` LONGTEXT COMMENT 'tag:2',
  \`title\` LONGTEXT COMMENT 'tag:3',
  \`start date\` LONGTEXT COMMENT 'tag:4',
  \`end date\` LONGTEXT COMMENT 'tag:5',
  PRIMARY KEY (id)
);
SQL
    run dolt table import -u employees `batshelper employees-tbl-schema-unordered.json`
    echo "$output"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Rows Processed: 3, Additions: 3, Modifications: 0, Had No Effect: 0" ]] || false
    [[ "$output" =~ "Import completed successfully." ]] || false
    run dolt schema export employees
    [[ "$status" -eq 0 ]]
    [[ "${lines[1]}" =~ "id" ]]         || false
    [[ "${lines[2]}" =~ "first name" ]] || false
    [[ "${lines[3]}" =~ "last name" ]]  || false
    [[ "${lines[4]}" =~ "title" ]]      || false
    [[ "${lines[5]}" =~ "start date" ]] || false
    [[ "${lines[6]}" =~ "end date" ]]   || false
}

@test "import-update-tables: update table with a csv with columns in different order" {
    dolt sql <<SQL
CREATE TABLE employees (
  \`id\` LONGTEXT NOT NULL COMMENT 'tag:0',
  \`first name\` LONGTEXT COMMENT 'tag:1',
  \`last name\` LONGTEXT COMMENT 'tag:2',
  \`title\` LONGTEXT COMMENT 'tag:3',
  \`start date\` LONGTEXT COMMENT 'tag:4',
  \`end date\` LONGTEXT COMMENT 'tag:5',
  PRIMARY KEY (id)
);
SQL
    run dolt table import -u employees `batshelper employees-tbl-schema-unordered.csv`
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Rows Processed: 3, Additions: 3, Modifications: 0, Had No Effect: 0" ]] || false
    [[ "$output" =~ "Import completed successfully." ]] || false
    run dolt schema export employees
    [[ "$status" -eq 0 ]]
    [[ "${lines[1]}" =~ "id" ]]         || false
    [[ "${lines[2]}" =~ "first name" ]] || false
    [[ "${lines[3]}" =~ "last name" ]]  || false
    [[ "${lines[4]}" =~ "title" ]]      || false
    [[ "${lines[5]}" =~ "start date" ]] || false
    [[ "${lines[6]}" =~ "end date" ]]   || false
}

@test "import-update-tables: update table with incorrect length char throws bad row error" {
    cat <<DELIM > 1pk1col-rpt-chars.csv
pk,c
1,"123456"
DELIM

    dolt sql < 1pk1col-char-sch.sql
    run dolt table import -u test 1pk1col-rpt-chars.csv
    [ "$status" -eq 1 ]
    [[ "$output" =~ "A bad row was encountered while moving data" ]] || false
    [[ "$output" =~ "Bad Row:" ]] || false
    [[ "$output" =~ '"123456" is not valid for column "c" (type "CHAR(5)")' ]] || false
}

@test "import-update-tables: update table with repeat pk in csv throws error" {
    cat <<DELIM > 1pk5col-rpt-ints.csv
pk,c1,c2,c3,c4,c5
1,1,2,3,4,5
1,1,2,3,4,5
DELIM

    dolt sql < 1pk5col-ints-sch.sql
    run dolt table import -u test 1pk5col-rpt-ints.csv
    [ "$status" -eq 1 ]
    [[ "$output" =~ "A bad row was encountered while moving data" ]] || false
    [[ "$output" =~ "Bad Row: c4:4 | pk:1 | c3:3 | c5:5 | c1:1 | c2:2" ]] || false

    # Works with --continue
    run dolt table import -u --continue test 1pk5col-rpt-ints.csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "The following rows were skipped:" ]] || false
    [[ "$output" =~ "1,1,2,3,4,5" ]] || false
    [[ "$output" =~ "Rows Processed: 1, Additions: 1, Modifications: 0, Had No Effect: 0" ]] || false
    [[ "$output" =~ "Lines skipped: 1" ]] || false
    [[ "$output" =~ "Import completed successfully." ]] || false
}

@test "import-update-tables: importing into new table renders bad rows" {
    cat <<DELIM > 1pk5col-rpt-ints.csv
pk,c1,c2,c3,c4,c5
1,1,2,3,4,5
1,1,2,3,4,7
1,1,2,3,4,8
DELIM

    dolt sql < 1pk5col-ints-sch.sql
    run dolt table import -u --continue test 1pk5col-rpt-ints.csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "The following rows were skipped:" ]] || false
    [[ "$output" =~ "1,1,2,3,4,7" ]] || false
    [[ "$output" =~ "1,1,2,3,4,8" ]] || false
    [[ "$output" =~ "Rows Processed: 1, Additions: 1, Modifications: 0, Had No Effect: 0" ]] || false
    [[ "$output" =~ "Lines skipped: 2" ]] || false
    [[ "$output" =~ "Import completed successfully." ]] || false

    # Output to a file from the error stderr
    dolt sql -q "DELETE FROM test WHERE pk = 1"
    run dolt table import -u --continue test 1pk5col-rpt-ints.csv
    [ "$status" -eq 0 ]
    [[ "$output" =~ "The following rows were skipped:" ]] || false
    [[ "$output" =~ "1,1,2,3,4,7" ]] || false
    [[ "$output" =~ "1,1,2,3,4,8" ]] || false
}

@test "import-update-tables: subsequent runs of same import with duplicate keys produces no modifications" {
    cat <<DELIM > 1pk5col-rpt-ints.csv
pk,c1,c2,c3,c4,c5
1,1,2,3,4,5
1,1,2,3,4,7
1,1,2,3,4,8
DELIM

    dolt sql < 1pk5col-ints-sch.sql
    dolt table import -u --continue test 1pk5col-rpt-ints.csv
    run dolt table import -u --continue test 1pk5col-rpt-ints.csv
    [ "$status" -eq 0 ]
    skip "Running this file on repeat produces modifications"
    ! [[ "$output" =~ "Modifications: 2" ]] || falsa 
}

@test "import-update-tables: importing some columns does not overwrite columns not part of the import" {
  dolt sql <1pk5col-ints-sch.sql
  echo -e 'pk,c1\n1,1\n2,6'|dolt table import -u test
  echo -e 'pk,c2\n1,2\n2,7'|dolt table import -u test
  echo -e 'pk,c3,c4,c5\n1,3,4,5\n2,8,9,10'|dolt table import -u test

  EXPECTED=$(echo -e "pk,c1,c2,c3,c4,c5\n1,1,2,3,4,5\n2,6,7,8,9,10")
  run dolt sql -r csv -q 'SELECT * FROM test'
  [ "$status" -eq 0 ]
  [[ "$output" =~ "$EXPECTED" ]] || false
}
