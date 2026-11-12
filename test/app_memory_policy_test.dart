import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:arcadiaplus/src/utils/app_memory_policy.dart';
import 'package:arcadiaplus/src/widgets/wallpaper_backdrop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
    'cache cleanup evicts retained entries without killing live images',
    (tester) async {
      final cache = ImageCache();
      final image = await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
        final picture = recorder.endRecording();
        final image = await picture.toImage(16, 16);
        picture.dispose();
        return image;
      });
      final completer = OneFrameImageStreamCompleter(
        Future.value(ImageInfo(image: image!)),
      );
      cache.putIfAbsent('retained', () => completer);
      final listener = ImageStreamListener((info, _) => info.dispose());
      completer.addListener(listener);
      await tester.pump();
      final bytes = cache.currentSizeBytes;
      expect(bytes, greaterThan(0));
      expect(AppMemoryPolicy.releaseImageCache(cache), bytes);
      expect(cache.currentSizeBytes, 0);
      expect(cache.liveImageCount, 1);
      completer.removeListener(listener);
      cache.clearLiveImages();
    },
  );
  test('image cache retention has a mobile budget', () {
    final cache = ImageCache();
    AppMemoryPolicy.configure(cache, platform: TargetPlatform.android);
    expect(cache.maximumSizeBytes, 16 * 1024 * 1024);
    expect(cache.maximumSize, 48);
  });

  testWidgets(
    'a tall wallpaper decodes inside both bounds without stretching',
    (tester) async {
      late ImageProvider provider;
      final directory = (await tester.runAsync(
        () => Directory.systemTemp.createTemp('wallpaper-memory-'),
      ))!;
      final file = File('${directory.path}/tall.png');
      await tester.runAsync(() async {
        final recorder = ui.PictureRecorder();
        Canvas(recorder).drawColor(Colors.blue, BlendMode.src);
        final picture = recorder.endRecording();
        final original = await picture.toImage(20, 5000);
        final bytes = (await original.toByteData(
          format: ui.ImageByteFormat.png,
        ))!;
        await file.writeAsBytes(bytes.buffer.asUint8List());
        original.dispose();
        picture.dispose();
      });
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              provider = WallpaperBackdrop.imageProvider(
                context,
                file.path,
                zoom: 4,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      await tester.runAsync(() async {
        final done = Completer<ImageInfo>();
        final stream = provider.resolve(ImageConfiguration.empty);
        final listener = ImageStreamListener(
          (info, _) => done.complete(info),
          onError: (Object error, StackTrace? stack) =>
              done.completeError(error, stack),
        );
        stream.addListener(listener);
        try {
          final info = await done.future.timeout(const Duration(seconds: 10));
          expect(info.image.height, lessThanOrEqualTo(2048));
          expect(info.image.width, lessThan(20));
          expect(info.image.height / info.image.width, closeTo(250, 30));
          info.dispose();
        } finally {
          stream.removeListener(listener);
          await provider.evict();
          await directory.delete(recursive: true);
        }
      });
    },
  );
}
