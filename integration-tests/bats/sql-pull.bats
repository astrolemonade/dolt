#!/usr/bin/env bats
load $BATS_TEST_DIRNAME/helper/common.bash

setup() {
    setup_common

    TESTDIRS=$(pwd)/testdirs
    mkdir -p $TESTDIRS/{rem1,repo1}

    # repo1 -> rem1 -> repo2
    cd $TESTDIRS/repo1
    dolt init
    dolt branch feature
    dolt remote add origin file://../rem1
    dolt remote add test-remote file://../rem1
    dolt push origin main

    cd $TESTDIRS
    dolt clone file://rem1 repo2
    cd $TESTDIRS/repo2
    dolt log
    dolt branch feature
    dolt remote add test-remote file://../rem1

    # table and commits only present on repo1, rem1 at start
    cd $TESTDIRS/repo1
    dolt sql -q "create table t1 (a int primary key, b int)"
    dolt add .
    dolt commit -am "First commit"
    dolt sql -q "insert into t1 values (0,0)"
    dolt commit -am "Second commit"
    dolt push origin main
    cd $TESTDIRS
}

teardown() {
    teardown_common
    rm -rf $TESTDIRS
}

@test "sql-pull: dolt_pull main" {
    cd repo2
    dolt sql -q "call dolt_pull('origin')"
    run dolt sql -q "show tables" -r csv
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" =~ "Table" ]] || false
    [[ "$output" =~ "t1" ]] || false
}

@test "sql-pull: dolt_pull custom remote" {
    cd repo2
    dolt sql -q "call dolt_pull('test-remote')"
    run dolt sql -q "show tables" -r csv
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" =~ "Table" ]] || false
    [[ "$output" =~ "t1" ]] || false
}

@test "sql-pull: dolt_pull default origin" {
    cd repo2
    dolt remote remove test-remote
    dolt sql -q "call dolt_pull()"
    run dolt sql -q "show tables" -r csv
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" =~ "Table" ]] || false
    [[ "$output" =~ "t1" ]] || false
}

@test "sql-pull: dolt_pull default custom remote" {
    cd repo2
    dolt remote remove origin
    dolt sql -q "call dolt_pull()"
    run dolt sql -q "show tables" -r csv
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" =~ "Table" ]] || false
    [[ "$output" =~ "t1" ]] || false
}

@test "sql-pull: dolt_pull up to date does not error" {
    cd repo2
    dolt sql -q "call dolt_pull('origin')"
    dolt sql -q "call dolt_pull('origin')"
    run dolt sql -q "show tables" -r csv
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" =~ "Table" ]] || false
    [[ "$output" =~ "t1" ]] || false
}

@test "sql-pull: dolt_pull unknown remote fails" {
    cd repo2
    run dolt sql -q "call dolt_pull('unknown')"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "fatal: remote 'unknown' not found" ]] || false
    [[ ! "$output" =~ "panic" ]] || false
}

@test "sql-pull: dolt_pull unknown feature branch fails" {
    cd repo2
    dolt checkout feature
    run dolt sql -q "call dolt_pull('origin')"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "You asked to pull from the remote 'origin', but did not specify a branch" ]] || false
    [[ ! "$output" =~ "panic" ]] || false
}

@test "sql-pull: dolt_pull feature branch" {
    cd repo1
    dolt checkout feature
    dolt push --set-upstream origin feature

    cd ../repo2
    dolt checkout feature
    dolt push --set-upstream origin feature

    cd ../repo1
    dolt merge main
    dolt push

    cd ../repo2
    dolt sql -q "call dolt_pull('origin')"
    run dolt sql -q "show tables" -r csv
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" =~ "Table" ]] || false
    [[ "$output" =~ "t1" ]] || false
}

@test "sql-pull: dolt_checkout after dolt_fetch a new feature branch" {
    cd repo1
    dolt checkout -b feature2
    dolt sql -q "create table t2 (i int primary key);"
    dolt sql -q "call dolt_add('.');"
    dolt sql -q "call dolt_commit('-am', 'create t2')"
    dolt push --set-upstream origin feature2

    cd ../repo2
    dolt sql -q "CALL dolt_fetch('origin', 'feature2')"
    run dolt sql -q "call dolt_checkout('feature2'); show tables" -r csv
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 6 ]
    [[ "$output" =~ "Table" ]] || false
    [[ "$output" =~ "t1" ]] || false
    [[ "$output" =~ "t2" ]] || false
}

@test "sql-pull: dolt_pull force" {
    cd repo1
    # disable foreign key checks to create merge conflicts
    dolt sql <<SQL
SET FOREIGN_KEY_CHECKS=0;
CREATE TABLE colors (
    id INT NOT NULL,
    color VARCHAR(32) NOT NULL,

    PRIMARY KEY (id),
    INDEX color_index(color)
);
CREATE TABLE objects (
    id INT NOT NULL,
    name VARCHAR(64) NOT NULL,
    color VARCHAR(32)
);
SQL
    dolt commit -A -m "Commit1"
    dolt push origin main

    cd ../repo2
    dolt pull
    dolt sql -q "alter table objects add constraint color FOREIGN KEY (color) REFERENCES colors(color)"
    dolt commit -A -m "Commit2"

    cd ../repo1
    dolt sql -q "INSERT INTO objects (id,name,color) VALUES (1,'truck','red'),(2,'ball','green'),(3,'shoe','blue')"
    dolt commit -A -m "Commit3"
    dolt push origin main

    cd ../repo2
    run dolt sql -q "call dolt_pull()"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Constraint violations" ]] || false

    run dolt sql -q "call dolt_pull('--force')"
    [ "$status" -eq 0 ]
    run dolt sql -q "select * from objects"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "truck" ]] || false
    [[ "$output" =~ "ball" ]] || false
    [[ "$output" =~ "shoe" ]] || false
}

@test "sql-pull: dolt_pull squash" {
    cd repo2
    dolt sql -q "create table t2 (i int primary key);"
    dolt commit -Am "commit 1"

    dolt sql -q "CALL dolt_pull('--squash', 'origin')"
    run dolt sql -q "show tables" -r csv
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 3 ]
    [[ "$output" =~ "Table" ]] || false
    [[ "$output" =~ "t1" ]] || false
    [[ "$output" =~ "t2" ]] || false

    run dolt log
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Merge branch" ]] || false
    [[ ! "$output" =~ "Second commit" ]] || false
    [[ ! "$output" =~ "First commit" ]] || false
}

@test "sql-pull: dolt_pull --noff flag" {
    cd repo2
    dolt sql -q "CALL dolt_pull('--no-ff', 'origin')"
    dolt status
    
    run dolt log -n 1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Merge branch 'main'" ]] || false

    run dolt sql -q "show tables" -r csv
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" =~ "Table" ]] || false
    [[ "$output" =~ "t1" ]] || false
}

@test "sql-pull: empty remote name does not panic" {
    cd repo2
    dolt sql -q "call dolt_pull('')"
}

@test "sql-pull: dolt_pull dirty working set fails" {
    cd repo2
    dolt sql -q "create table t2 (a int)"
    run dolt sql -q "call dolt_pull('origin')"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "cannot merge with uncommitted changes" ]] || false
}

@test "sql-pull: dolt_pull tag" {
    cd repo1
    dolt tag v1
    dolt push origin v1
    dolt tag

    cd ../repo2
    dolt sql -q "call dolt_pull('origin')"
    run dolt tag
    [ "$status" -eq 0 ]
    [[ "$output" =~ "v1" ]] || false
}

@test "sql-pull: dolt_pull tags only for resolved commits" {
    cd repo1
    dolt tag v1 head
    dolt tag v2 head^
    dolt push origin v1
    dolt push origin v2

    dolt checkout feature
    dolt sql -q "create table t2 (a int)"
    dolt add .
    dolt commit -am "feature commit"
    dolt tag v3
    dolt push origin v3

    cd ../repo2
    dolt sql -q "call dolt_pull('origin')"
    run dolt tag
    [ "$status" -eq 0 ]
    [[ "$output" =~ "v1" ]] || false
    [[ "$output" =~ "v2" ]] || false
    [[ ! "$output" =~ "v3" ]] || false
}

@test "sql-pull: dolt_pull with remote and remote ref" {
    cd repo1
    dolt checkout feature
    dolt checkout -b newbranch
    run dolt sql -q "show tables"
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "t1" ]] || false

    # Specifying a non-existent remote branch returns an error
    run dolt sql -q "call dolt_pull('origin', 'doesnotexist');"
    [ "$status" -eq 1 ]
    [[ "$output" =~ 'branch "doesnotexist" not found on remote' ]] || false

    # Explicitly specifying the remote and branch will merge in that branch
    run dolt sql -q "call dolt_pull('origin', 'main');"
    [ "$status" -eq 0 ]
    run dolt sql -q "show tables"
    [ "$status" -eq 0 ]
    [[ "$output" =~ "t1" ]] || false
    run dolt status
    [ "$status" -eq 0 ]
    [[ "$output" =~ "working tree clean" ]] || false

    # Make a conflicting working set change and test that pull complains
    dolt reset --hard HEAD^1
    dolt sql -q "insert into t1 values (0, 100);"
    run dolt sql -q "call dolt_pull('origin', 'main');"
    [ "$status" -eq 1 ]
    [[ "$output" =~ 'cannot merge with uncommitted changes' ]] || false

    # Commit changes and test that a merge conflict fails the pull
    dolt commit -am "adding new t1 table"
    run dolt sql -q "call dolt_pull('origin', 'main');"
    [ "$status" -eq 1 ]
    [[ "$output" =~ "| fast_forward | conflicts |" ]] || false
    [[ "$output" =~ "| 0            | 1         |" ]] || false
}

@test "sql-pull: dolt_pull also fetches, but does not merge other branches" {
    cd repo1
    dolt checkout -b other
    dolt push --set-upstream origin other
    dolt checkout feature
    dolt push origin feature

    cd ../repo2
    dolt fetch
    # this checkout will set upstream because 'other' branch is a new branch that matches one of remote tracking branch
    dolt checkout other
    # this checkout will not set upstream because this 'feature' branch existed before matching remote tracking branch was created
    dolt checkout feature
    dolt push --set-upstream origin feature

    cd ../repo1
    dolt merge main
    dolt push origin feature
    dolt checkout other
    dolt commit --allow-empty -m "new commit on other"
    dolt push

    cd ../repo2
    dolt sql -q "call dolt_pull()"
    run dolt sql -q "show tables" -r csv
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" =~ "Table" ]] || false
    [[ "$output" =~ "t1" ]] || false

    dolt checkout other
    run dolt log --oneline -n 1
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "new commit on other" ]] || false

    run dolt status
    [ "$status" -eq 0 ]
    [[ "$output" =~ "behind 'origin/other' by 1 commit" ]] || false
}

@test "sql-pull: dolt_pull commits successful merge on current branch" {
    cd repo1
    dolt checkout -b other
    dolt push --set-upstream origin other

    cd ../repo2
    dolt fetch
    # this checkout will set upstream because 'other' branch is a new branch that matches one of remote tracking branch
    dolt checkout other

    cd ../repo1
    dolt sql -q "insert into t1 values (1, 2)"
    dolt commit -am "add (1,2) to t1"
    dolt push

    cd ../repo2
    run dolt sql -q "select * from t1" -r csv
    [ "$status" -eq 0 ]
    [[ ! "$output" =~ "1,2" ]] || false

    dolt sql -q "insert into t1 values (2, 3)"
    dolt commit -am "add (2,3) to t1"
    run dolt sql -q "call dolt_pull()"
    [ "$status" -eq 0 ]

    run dolt log --oneline -n 1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Merge branch 'other' of" ]] || false
    [[ ! "$output" =~ "add (1,2) to t1" ]] || false
    [[ ! "$output" =~ "add (2,3) to t1" ]] || false
}

@test "sql-pull: --no-ff and --no-commit" {
    cd repo2
    run dolt sql -q "show tables" -r csv
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 1 ]

    dolt sql -q "call dolt_pull('--no-ff', '--no-commit')"
    run dolt sql -q "show tables" -r csv
    [ "$status" -eq 0 ]
    [ "${#lines[@]}" -eq 2 ]
    [[ "$output" =~ "t1" ]] || false

    dolt commit -m "merge from origin"
    run dolt log
    [ "$status" -eq 0 ]
    [[ "$output" =~ "merge from origin" ]] || false
}

@test "sql-pull: pull two different branches in the same session" {
    cd repo2
    dolt pull
    
    dolt sql <<SQL
    call dolt_checkout('main');
    insert into t1 values (1,1), (2,2);
    call dolt_commit('-Am', 'new rows in t1');
    call dolt_checkout('-b', 'b1');
    insert into t1 values (3,3);
    call dolt_commit('-Am', 'new row on b1');
SQL

    dolt push origin main
    dolt checkout b1
    dolt push origin b1
    dolt checkout main

    cd ../repo1
    dolt pull origin main
    dolt checkout b1
    dolt pull origin b1

    cd ../repo2
    dolt sql <<SQL
    call dolt_checkout('main');
    insert into t1 values (4,4);
    call dolt_commit('-Am', 'new row in t1');
    call dolt_checkout('b1');
    insert into t1 values (5,5);
    call dolt_commit('-Am', 'new row on b1');
SQL

    dolt push origin main
    dolt checkout b1
    dolt push origin b1
    dolt checkout main
    
    cd ../repo1

    dolt sql <<SQL
    call dolt_checkout('main');
    insert into t1 values (6,6);
    call dolt_commit('-Am', 'new row in t1');
    call dolt_checkout('b1');
    insert into t1 values (7,7);
    call dolt_commit('-Am', 'new row on b1');
SQL

    # Now pull from both branches and make sure we can commit the result in a single tx
    dolt sql <<SQL
    set autocommit = 0;
    call dolt_checkout('main');
    call dolt_pull('origin', 'main');
    call dolt_checkout('b1');
    call dolt_pull('origin', 'b1');
    commit;
SQL
}

@test "sql-pull: pull two different branches same session, already up to date" {
    cd repo2
    dolt pull
    
    dolt sql <<SQL
    call dolt_checkout('main');
    insert into t1 values (1,1), (2,2);
    call dolt_commit('-Am', 'new rows in t1');
    call dolt_checkout('-b', 'b1');
    insert into t1 values (3,3);
    call dolt_commit('-Am', 'new row on b1');
SQL

    dolt push origin main
    dolt checkout b1
    dolt push origin b1
    dolt checkout main

    cd ../repo1
    dolt pull origin main
    dolt checkout b1
    dolt pull origin b1

    # Make sure we can commit the result after a no-op pull on two branches
    dolt sql <<SQL
    set autocommit=off;
    call dolt_checkout('main');
    call dolt_pull('origin', 'main');
    call dolt_checkout('b1');
    call dolt_pull('origin', 'b1');
    commit;
SQL
}


