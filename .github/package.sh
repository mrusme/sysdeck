#!/bin/sh
set -eu

target=$1
shift

version=$(LD_BIND_NOW=1 "$@" zig-out/bin/sysdeck --version)
echo "$version"
if [ "${GITHUB_REF_TYPE:-}" = tag ] && [ "$version" != "sysdeck ${GITHUB_REF_NAME#v}" ]; then
  echo "the binary reports '$version', but the tag is $GITHUB_REF_NAME" >&2
  exit 1
fi

ref=$(printf '%s' "$GITHUB_REF_NAME" | tr / -)
name="sysdeck-$ref-$target"
mkdir -p "dist/$name"
cp zig-out/bin/sysdeck LICENSE README.md config.example.toml "dist/$name/"
tar -czf "dist/$name.tar.gz" -C dist "$name"
rm -r "dist/$name"
