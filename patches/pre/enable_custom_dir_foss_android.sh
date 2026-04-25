#!/usr/bin/env bash
#
# Enables custom directories for the Android FOSS build

# Update Manifest

MANIFEST="android/app/src/main/AndroidManifest.xml"

echo -n "Adding MANAGE_EXTERNAL_STORAGE permission to AndroidManifest.xml: "
if grep -q "MANAGE_EXTERNAL_STORAGE" "$MANIFEST"; then
  echo "already done"
else
  echo "adding"
  sed -i 's|<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />|<uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />\n    <uses-permission android:name="android.permission.MANAGE_EXTERNAL_STORAGE" />|' "$MANIFEST"
fi

# add in custom_directory functionality

DIRECTORY_SELECTOR="lib/components/settings/settings_directory_selector.dart"


sed -i "s|import 'package:flutter/material.dart';|import 'package:flutter/material.dart';\nimport 'package:saber/components/settings/custom_dir.dart';|" "$DIRECTORY_SELECTOR"
sed -i 's/  void _onConfirm() {/  void _onConfirm() async {/' "$DIRECTORY_SELECTOR"
sed -i '/    context\.pop();/{n; s/^  }/    await onConfirmAndroid(context, _directory);\n  }/}' "$DIRECTORY_SELECTOR"