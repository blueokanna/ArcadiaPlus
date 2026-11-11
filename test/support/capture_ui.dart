import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

Future<void> captureTestUi(
  WidgetTester tester,
  GlobalKey key,
  String name,
) async {
  if (!const bool.fromEnvironment('CAPTURE_UI')) return;
  await tester.runAsync(() async {
    final boundary =
        key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
    final image = await boundary.toImage();
    try {
      final data = (await image.toByteData(format: ui.ImageByteFormat.png))!;
      final file = File('.dart_tool/ui-previews/$name.png');
      await file.parent.create(recursive: true);
      await file.writeAsBytes(data.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}
