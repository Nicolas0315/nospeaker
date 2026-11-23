#!/bin/sh
set -e
cd "$(dirname "$0")"
swiftc -O -o trackpad-sounds main.swift
echo "built ./trackpad-sounds"
