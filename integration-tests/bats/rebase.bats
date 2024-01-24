#!/usr/bin/env bats
load $BATS_TEST_DIRNAME/helper/common.bash

setup() {
    setup_common
    dolt sql -q "CREATE table t1 (pk int primary key, c int);"
    dolt add t1
    dolt commit -m "main commit 1"
    dolt branch b1
    dolt sql -q "INSERT INTO t1 VALUES (1,1);"
    dolt add t1
    dolt commit -m "main commit 2"

    dolt checkout b1
    dolt sql -q "CREATE table t2 (pk int primary key);"
    dolt add t2
    dolt commit -m "b1 commit 1"

    dolt checkout main
}

teardown() {
    assert_feature_version
    teardown_common
}

setupCustomEditorScript() {
    touch rebaseScript.sh
    echo "#!/bin/bash" >> rebaseScript.sh
    if [ $# -eq 1 ]; then
      echo "mv $1 \$1" >> rebaseScript.sh
    fi
    chmod +x rebaseScript.sh
    export EDITOR=$PWD/rebaseScript.sh
    export DOLT_TEST_FORCE_OPEN_EDITOR="1"
}

@test "rebase: no rebase in progress errors" {
    run dolt rebase --abort
    [ "$status" -eq 1 ]
    [[ "$output" =~ "no rebase in progress" ]] || false

    run dolt rebase --continue
    [ "$status" -eq 1 ]
    [[ "$output" =~ "no rebase in progress" ]] || false
}

@test "rebase: -i flag required" {
    run dolt rebase b1
    [ "$status" -eq 1 ]
    [[ "$output" =~ "non-interactive rebases not currently supported" ]] || false
}

@test "rebase: bad args" {
    run dolt rebase -i
    [ "$status" -eq 1 ]
    [[ "$output" =~ "not enough args" ]] || false

    run dolt rebase -i main b1
    [ "$status" -eq 1 ]
    [[ "$output" =~ "rebase takes at most one positional argument" ]] || false

    run dolt rebase --abrot
    [ "$status" -eq 1 ]
    [[ "$output" =~ "error: unknown option \`abrot'" ]] || false

    run dolt rebase -i foo
    [ "$status" -eq 1 ]
    [[ "$output" =~ "branch not found: foo" ]] || false
}

@test "rebase: cannot rebase with dirty working set" {
    dolt sql -q "INSERT INTO t1 VALUES (2,2);"
    run dolt rebase -i b1
    [ "$status" -eq 1 ]
    [[ "$output" =~ "cannot start a rebase with uncommitted changes" ]] || false
}

@test "rebase: cannot rebase during active merge" {
    dolt checkout b1
    dolt sql -q "INSERT INTO t1 VALUES (1,2);"
    dolt add t1
    dolt commit -m "b1 commit 2"

    run dolt merge main
    [ "$status" -eq 1 ]
    [[ "$output" =~ "Automatic merge failed" ]] || false

    run dolt rebase -i main
    [ "$status" -eq 1 ]
    [[ "$output" =~ "unable to start rebase while a merge is in progress – abort the current merge before proceeding" ]] || false
}

@test "rebase: rebase working branch already exists" {
    dolt checkout b1
    dolt branch dolt_rebase_b1

    run dolt rebase -i main
    [ "$status" -eq 1 ]
    [[ "$output" =~ "fatal: A branch named 'dolt_rebase_b1' already exists." ]] || false
}

@test "rebase: verify custom script" {
    setupCustomEditorScript "rebasePlan.txt"

    dolt checkout b1
    run dolt show head
    [ "$status" -eq 0 ]
    COMMIT1=${lines[0]:12:32}

    touch rebasePlan.txt
    echo "pick $COMMIT1 b1 commit 1" >> rebasePlan.txt

    run dolt rebase -i main
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Successfully rebased and updated refs/heads/b1" ]] || false

    run dolt log
    [ "$status" -eq 0 ]
    [[ "$output" =~ "b1 commit 1" ]] || false
    [[ "$output" =~ "main commit 2" ]] || false
}

@test "rebase: basic rebase" {
    setupCustomEditorScript

    dolt checkout b1
    run dolt rebase -i main
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Successfully rebased and updated refs/heads/b1" ]] || false

    run dolt log
    [ "$status" -eq 0 ]
    [[ "$output" =~ "main commit 2" ]] || false
}

@test "rebase: failed rebase will abort and clean up" {
    setupCustomEditorScript "invalidRebasePlan.txt"
    dolt checkout b1

    touch invalidRebasePlan.txt
    echo "foo" >> invalidRebasePlan.txt
    run dolt rebase -i main
    [ "$status" -eq 1 ]
    [[ "$output" =~ "invalid line 0: foo" ]] || false

    run dolt branch
    [ "$status" -eq 0 ]
    ! [[ "$output" =~ "dolt_rebase_b1" ]] || false

    run dolt rebase --continue
    [ "$status" -eq 1 ]
    [[ "$output" =~ "no rebase in progress" ]] || false
}

@test "rebase: invalid rebase plan" {
    setupCustomEditorScript "invalidRebasePlan.txt"

    dolt checkout b1

    touch invalidRebasePlan.txt
    echo "foo" >> invalidRebasePlan.txt
    run dolt rebase -i main
    [ "$status" -eq 1 ]
    [[ "$output" =~ "invalid line 0: foo" ]] || false

    touch invalidRebasePlan.txt
    echo "pick foo main commit 1" >> invalidRebasePlan.txt
    run dolt rebase -i main
    [ "$status" -eq 1 ]
    [[ "$output" =~ "invalid commit hash: foo" ]] || false
}

@test "rebase: empty rebase plan aborts the rebase" {
    setupCustomEditorScript "emptyRebasePlan.txt"
    touch emptyRebasePlan.txt
    echo "# " >> emptyRebasePlan.txt
    echo "# commented out lines don't count" >> emptyRebasePlan.txt

    dolt checkout b1
    run dolt rebase -i main
    [ "$status" -eq 0 ]
    [[ "$output" =~ "rebase aborted" ]] || false

    run dolt log
    [ "$status" -eq 0 ]
    ! [[ "$output" =~ "main commit 2" ]] || false

    run dolt rebase --continue
    [ "$status" -eq 1 ]
    [[ "$output" =~ "no rebase in progress" ]] || false

    run dolt branch
    [ "$status" -eq 0 ]
    ! [[ "$output" =~ "dolt_rebase_b1" ]] || false
}

@test "rebase: multi step rebase" {
    setupCustomEditorScript "multiStepPlan.txt"

    dolt checkout b1
    run dolt show head
    [ "$status" -eq 0 ]
    COMMIT1=${lines[0]:12:32}

    dolt sql -q "insert into t2 values (1);"
    dolt commit -am "b1 commit 2"
    run dolt show head
    [ "$status" -eq 0 ]
    COMMIT2=${lines[0]:12:32}

    dolt sql -q "insert into t2 values (2);"
    dolt commit -am "b1 commit 3"
    run dolt show head
    [ "$status" -eq 0 ]
    COMMIT3=${lines[0]:12:32}

    dolt sql -q "insert into t2 values (3);"
    dolt commit -am "b1 commit 4"
    run dolt show head
    [ "$status" -eq 0 ]
    COMMIT4=${lines[0]:12:32}

    dolt sql -q "insert into t2 values (4);"
    dolt commit -am "b1 commit 5"
    run dolt show head
    [ "$status" -eq 0 ]
    COMMIT5=${lines[0]:12:32}

    dolt sql -q "insert into t2 values (5);"
    dolt commit -am "b1 commit 6"
    run dolt show head
    [ "$status" -eq 0 ]
    COMMIT6=${lines[0]:12:32}

    dolt sql -q "insert into t2 values (6);"
    dolt commit -am "b1 commit 7"
    run dolt show head
    [ "$status" -eq 0 ]
    COMMIT7=${lines[0]:12:32}

    touch multiStepPlan.txt
    echo "pick $COMMIT1 b1 commit 1" >> multiStepPlan.txt
    echo "squash $COMMIT2 b1 commit 2" >> multiStepPlan.txt
    echo "squash $COMMIT3 b1 commit 3" >> multiStepPlan.txt
    echo "drop $COMMIT4 b1 commit 4" >> multiStepPlan.txt
    echo "reword $COMMIT5 reworded!" >> multiStepPlan.txt
    echo "fixup $COMMIT6 b1 commit 6" >> multiStepPlan.txt
    echo "pick $COMMIT7 b1 commit 7" >> multiStepPlan.txt

    run dolt rebase -i main
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Successfully rebased and updated refs/heads/b1" ]] || false

    run dolt show head
    [ "$status" -eq 0 ]
    [[ "$output" =~ "b1 commit 7" ]] || false

    run dolt show head~1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "reworded!" ]] || false

    run dolt show head~2
    [ "$status" -eq 0 ]
    [[ "$output" =~ "b1 commit 1" ]] || false
    [[ "$output" =~ "b1 commit 2" ]] || false
    [[ "$output" =~ "b1 commit 3" ]] || false

    run dolt show head~3
    [ "$status" -eq 0 ]
    [[ "$output" =~ "main commit 2" ]] || false
}

@test "rebase: non-standard plan changes" {
    setupCustomEditorScript "nonStandardPlan.txt"

    dolt checkout -b b2
    dolt sql -q "CREATE table t3 (pk int primary key);"
    dolt add t3
    dolt commit -m "b2 commit 1"
    run dolt show head
    [ "$status" -eq 0 ]
    COMMIT1=${lines[0]:12:32}

    dolt sql -q "insert into t3 values (1);"
    dolt commit -am "b2 commit 2"
    dolt sql -q "insert into t3 values (2);"
    dolt commit -am "b2 commit 3"

    dolt checkout b1
    run dolt show head
    [ "$status" -eq 0 ]
    COMMIT2=${lines[0]:12:32}

    touch nonStandardPlan.txt
    echo "pick $COMMIT1 b2 commit 1" >> nonStandardPlan.txt
    echo "pick $COMMIT2 b1 commit 1" >> nonStandardPlan.txt

    dolt checkout b2
    run dolt rebase -i main
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Successfully rebased and updated refs/heads/b2" ]] || false

    run dolt show head
    [ "$status" -eq 0 ]
    [[ "$output" =~ "b1 commit 1" ]] || false

    run dolt show head~1
    [ "$status" -eq 0 ]
    [[ "$output" =~ "b2 commit 1" ]] || false

    run dolt show head~2
    [ "$status" -eq 0 ]
    [[ "$output" =~ "main commit 2" ]] || false
}

@test "rebase: rebase skips merge commits" {
    setupCustomEditorScript

    dolt checkout b1
    dolt merge main -m "b1 merge commit"
    dolt sql -q "insert into t2 values (1);"
    dolt commit -am "b1 commit 2"

    dolt checkout main
    dolt sql -q "insert into t1 values (2,2);"
    dolt commit -am "main commit 3"
    dolt checkout b1

    run dolt rebase -i main
    [ "$status" -eq 0 ]
    [[ "$output" =~ "Successfully rebased and updated refs/heads/b1" ]] || false

    run dolt log
    [ "$status" -eq 0 ]
    [[ "$output" =~ "b1 commit 2" ]] || false
    [[ "$output" =~ "b1 commit 1" ]] || false
    [[ "$output" =~ "main commit 3" ]] || false
    ! [[ "$output" =~ "b1 merge commit" ]] || false
}

@test "rebase: rebase with data conflicts aborts" {
    setupCustomEditorScript

    dolt checkout b1
    dolt sql -q "INSERT INTO t1 VALUES (1,2);"
    dolt commit -am "b1 commit 2"

    run dolt rebase -i main
    [ "$status" -eq 1 ]
    [[ "$output" =~ "merge conflict detected while rebasing commit" ]] || false
    [[ "$output" =~ "the rebase has been automatically aborted" ]] || false

    run dolt rebase --continue
    [ "$status" -eq 1 ]
    [[ "$output" =~ "no rebase in progress" ]] || false

    run dolt branch
    [ "$status" -eq 0 ]
    ! [[ "$output" =~ "dolt_rebase_b1" ]] || false
}

@test "rebase: rebase with schema conflicts aborts" {
    setupCustomEditorScript

    dolt checkout b1
    dolt sql -q "ALTER TABLE t1 MODIFY COLUMN c varchar(100);"
    dolt commit -am "b1 commit 2"

    run dolt rebase -i main
    [ "$status" -eq 1 ]
    [[ "$output" =~ "merge conflict detected while rebasing commit" ]] || false
    [[ "$output" =~ "the rebase has been automatically aborted" ]] || false

    run dolt rebase --continue
    [ "$status" -eq 1 ]
    [[ "$output" =~ "no rebase in progress" ]] || false

    run dolt branch
    [ "$status" -eq 0 ]
    ! [[ "$output" =~ "dolt_rebase_b1" ]] || false
}
