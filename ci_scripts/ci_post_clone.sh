#!/bin/sh
# Xcode Cloud runs tests only. TestFlight and App Store builds stay on Codemagic, which owns the
# tag-derived build numbers the changelog keys depend on.
set -e
cd "$CI_PRIMARY_REPOSITORY_PATH"
cp RivuletCore/Config/Secrets.swift.template RivuletCore/Config/Secrets.swift
