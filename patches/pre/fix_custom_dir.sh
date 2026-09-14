#!/usr/bin/env bash
#
# Enables custom directories for the Android FOSS build

git -c user.name="aarron-lee" -c user.email="aarron-lee@users.noreply.github.com" am -3 < changes.patch
