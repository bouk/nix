#!/usr/bin/env bash

source common.sh

requireGit

clearStoreIfPossible

# Git repositories that use the reftable ref storage format.
repo=$TEST_ROOT/reftable
createGitRepo "$repo" "--ref-format=reftable"
[[ $(git -C "$repo" config extensions.refstorage) = reftable ]]

echo hello > "$repo/hello"
git -C "$repo" add hello
git -C "$repo" commit -m first
rev1=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" tag v1

echo world > "$repo/hello"
git -C "$repo" commit -am second
rev2=$(git -C "$repo" rev-parse HEAD)

git -C "$repo" checkout -b dev
echo dev > "$repo/hello"
git -C "$repo" commit -am dev
revDev=$(git -C "$repo" rev-parse HEAD)
git -C "$repo" checkout master

fetch() {
    nix eval --impure --raw --expr "let tree = builtins.fetchGit $1; in tree.rev + \" \" + builtins.readFile (tree + \"/hello\")"
}

# Local workdir.
[[ $(fetch "$repo") = "$rev2 world" ]]
[[ $(fetch "{ url = \"file://$repo\"; ref = \"dev\"; }") = "$revDev dev" ]]
[[ $(fetch "{ url = \"file://$repo\"; ref = \"refs/tags/v1\"; }") = "$rev1 hello" ]]
[[ $(fetch "{ url = \"file://$repo\"; rev = \"$rev1\"; }") = "$rev1 hello" ]]

# Dirty workdir.
echo dirty > "$repo/hello"
[[ $(nix eval --impure --raw --expr "builtins.readFile (builtins.fetchGit $repo + \"/hello\")") = dirty ]]
[[ $(nix eval --impure --raw --expr "(builtins.fetchGit $repo).dirtyRev") = "$rev2-dirty" ]]
git -C "$repo" checkout hello

# Remote fetch path.
export _NIX_FORCE_HTTP=1
[[ $(fetch "{ url = \"file://$repo\"; ref = \"dev\"; }") = "$revDev dev" ]]
[[ $(fetch "{ url = \"file://$repo\"; rev = \"$rev1\"; }") = "$rev1 hello" ]]
