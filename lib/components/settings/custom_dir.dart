import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:saber/components/theming/adaptive_alert_dialog.dart';
import 'package:saber/i18n/strings.g.dart';


Future<void> requestStoragePermission() async {
  final status = await Permission.manageExternalStorage.request();
  if (status.isDenied || status.isPermanentlyDenied) {
    openAppSettings();
  }
}

Future<void> onConfirmAndroid(BuildContext context, String directory) async {
  if (directory.startsWith('/data/user/')) return;
  if (await Permission.manageExternalStorage.isGranted) return;
  if (!context.mounted) return;

  showDialog(
    context: context,
    builder: (context) => AdaptiveAlertDialog(
      title: Text("Grant permission"),
      content: Text("Saber needs permission to access the directory you chose. Do you want to grant this permission?"),
      actions: [
        CupertinoDialogAction(
          onPressed: () => context.pop(),
          child: Text(t.settings.customDataDir.cancel),
        ),
        CupertinoDialogAction(
          isDefaultAction: true,
          onPressed: () {
            context.pop();
            requestStoragePermission();
          },
          child: Text("Yes"),
        ),
      ],
    ),
  );
}
