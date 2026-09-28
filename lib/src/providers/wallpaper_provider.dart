import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:arcadiaplus/src/services/storage_service.dart';
import 'package:arcadiaplus/src/services/wallpaper_service.dart';

/// Owns the wallpaper: which picture, how far it is blurred, how far it is
/// dimmed, and whether it is drawn at all.
///
/// The provider is deliberately the only thing that writes the record: the
/// backdrop widget reads it, the settings screen edits it, and neither touches
/// the file that [WallpaperService] keeps in step with the stored path.
class WallpaperProvider extends ChangeNotifier {
  /// Stored settings are written on a slider drag, which fires many times a
  /// second. Persisting every frame would trade disk writes for nothing, so
  /// writes are coalesced over this window and the UI still updates at once.
  static const Duration saveDebounce = Duration(milliseconds: 250);

  WallpaperSettings _settings = const WallpaperSettings();
  bool _isLoading = true;
  bool _isPicking = false;
  Object? _lastError;
  Timer? _pendingSave;

  WallpaperSettings get settings => _settings;

  /// False until the stored record has been read, so the backdrop does not
  /// flash an empty layer on the first frame and then redraw.
  bool get isLoading => _isLoading;

  /// True while the picker dialog is open.
  bool get isPicking => _isPicking;

  /// The last failure, for the settings screen to report. Cleared on the next
  /// successful action.
  Object? get lastError => _lastError;

  /// Whether this platform can show a wallpaper at all.
  ///
  /// `Image.file` has no file system behind it on the web, so the feature is
  /// absent there rather than broken.
  static bool get isSupported => !kIsWeb;

  /// Whether the picture should be drawn.
  bool get isVisible => _settings.isVisible;

  /// Sigma of the gaussian blur applied to the picture.
  double get blur => _settings.blur;

  /// Alpha of the scrim between the picture and the interface.
  double get dim => _settings.dim;

  /// Framing: which part of the picture the interface shows.
  double get alignmentX => _settings.alignmentX;
  double get alignmentY => _settings.alignmentY;
  double get zoom => _settings.zoom;

  String? get imagePath => _settings.imagePath;

  WallpaperProvider() {
    _load();
  }

  @override
  void dispose() {
    // A drag that ends just as the provider goes away still gets written;
    // dropping it would lose the last thing the user did.
    if (_pendingSave != null) {
      _pendingSave!.cancel();
      _persist();
    }
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final stored = await StorageService.instance.getWallpaperSettings();
      // A path that no longer resolves is worse than no path: it would leave
      // the settings screen claiming a wallpaper exists and the backdrop
      // silently drawing nothing. Self-heal instead.
      if (stored.hasImage &&
          !await WallpaperService.instance.isReadable(stored.imagePath!)) {
        debugPrint(
          'Stored wallpaper "${stored.imagePath}" is gone; forgetting it',
        );
        _settings = stored.copyWith(imagePath: null);
        await StorageService.instance.saveWallpaperSettings(_settings);
      } else {
        _settings = stored;
      }
    } catch (error) {
      debugPrint('Failed to load the wallpaper settings: $error');
      _lastError = error;
    } finally {
      _isLoading = false;
      notifyListeners();
    }
  }

  /// Shows the picker and stores what it returns.
  ///
  /// Returns true when a new picture was stored, so the caller can report
  /// success without re-reading the provider.
  Future<bool> pickImage() async {
    if (!isSupported || _isPicking) return false;

    _isPicking = true;
    _lastError = null;
    notifyListeners();

    try {
      final path = await WallpaperService.instance.pickAndStore();
      if (path == null) return false;

      final previous = _settings.imagePath;
      // A new picture gets a new framing: keeping the old pan and zoom would
      // apply a crop that was chosen for a different image.
      _settings = _settings.copyWith(
        imagePath: path,
        enabled: true,
        alignmentX: 0,
        alignmentY: 0,
        zoom: WallpaperSettings.minZoom,
      );
      _pendingSave?.cancel();
      _pendingSave = null;
      await StorageService.instance.saveWallpaperSettings(_settings);
      if (previous != null && previous != path) {
        await WallpaperService.forgetImage(previous);
      }
      return true;
    } catch (error) {
      debugPrint('Failed to store the picked wallpaper: $error');
      _lastError = error;
      return false;
    } finally {
      _isPicking = false;
      notifyListeners();
    }
  }

  void setEnabled(bool value) {
    _settings = _settings.copyWith(enabled: value);
    notifyListeners();
    _scheduleSave();
  }

  void setBlur(double value) {
    _settings = _settings.copyWith(blur: value);
    notifyListeners();
    _scheduleSave();
  }

  void setDim(double value) {
    _settings = _settings.copyWith(dim: value);
    notifyListeners();
    _scheduleSave();
  }

  /// Moves and magnifies the picture: which part of it the interface shows.
  ///
  /// The three values travel together because a gesture that pans and pinches
  /// at once produces all of them in one frame; writing them as one record
  /// keeps the backdrop and the settings preview on the same revision instead
  /// of racing between three notifications.
  void setFraming({
    required double alignmentX,
    required double alignmentY,
    required double zoom,
  }) {
    final next = _settings.copyWith(
      alignmentX: alignmentX,
      alignmentY: alignmentY,
      zoom: zoom,
    );
    if (next.alignmentX == _settings.alignmentX &&
        next.alignmentY == _settings.alignmentY &&
        next.zoom == _settings.zoom) {
      return;
    }
    _settings = next;
    notifyListeners();
    _scheduleSave();
  }

  /// Centres the picture at fill scale, which is what "no framing chosen"
  /// means and what a first-time image gets.
  void resetFraming() {
    setFraming(alignmentX: 0, alignmentY: 0, zoom: WallpaperSettings.minZoom);
  }

  /// Magnifies the picture around the point the alignment already holds fixed.
  void setZoom(double value) {
    setFraming(
      alignmentX: _settings.alignmentX,
      alignmentY: _settings.alignmentY,
      zoom: value,
    );
  }

  /// Forgets the picture and deletes the app's copy of it.
  Future<void> clearImage() async {
    final previous = _settings.imagePath;
    _settings = _settings.copyWith(imagePath: null);
    _lastError = null;
    notifyListeners();

    _pendingSave?.cancel();
    _pendingSave = null;
    await StorageService.instance.saveWallpaperSettings(_settings);
    if (previous != null) {
      await WallpaperService.forgetImage(previous);
    }
    await WallpaperService.instance.deleteStored();
  }

  /// Coalesces the writes a slider drag would otherwise make: one write per
  /// gesture instead of one per frame.
  void _scheduleSave() {
    _pendingSave?.cancel();
    _pendingSave = Timer(saveDebounce, _persist);
  }

  /// Writes the current record.
  ///
  /// Fire-and-forget on purpose: the UI already reflects the in-memory record,
  /// and a failed write is not something a user can act on mid-drag. It is
  /// logged rather than swallowed silently.
  void _persist() {
    _pendingSave = null;
    unawaited(
      StorageService.instance
          .saveWallpaperSettings(_settings)
          .catchError(
            (Object error) =>
                debugPrint('Failed to save the wallpaper settings: $error'),
          ),
    );
  }
}
