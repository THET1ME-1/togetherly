import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
import 'package:yandex_mobileads/mobile_ads.dart' as yandex;

/// Test ad unit IDs from Google for development.
/// Replace [adUnitId] with your real AdMob unit ID before release.
const String _testBannerAdUnit = 'ca-app-pub-3940256099942544/6300978111';

/// Yandex banner block id (waterfall fallback when AdMob has no fill).
/// Debug uses Yandex's official demo unit; release uses our real block.
const String _prodYandexBannerUnit = 'R-M-19386995-1';
const String _demoYandexBannerUnit = 'demo-banner-yandex';

/// A self-disposing banner ad that loads once and shows between content.
///
/// Waterfall: tries AdMob first; if AdMob reports no ad
/// ([BannerAdListener.onAdFailedToLoad]), falls back to a Yandex banner. Shows
/// nothing on web/desktop or when both networks fail.
class AdBanner extends StatefulWidget {
  final String adUnitId;

  /// The ad unit ID for this banner. Leave empty to use the test unit.
  final double height;

  const AdBanner({
    super.key,
    this.adUnitId = '',
    this.height = 50,
  });

  @override
  State<AdBanner> createState() => _AdBannerState();
}

class _AdBannerState extends State<AdBanner> {
  BannerAd? _ad;
  bool _loaded = false;
  String? _errorText;

  // Yandex fallback (used only after AdMob reports no fill).
  yandex.BannerAd? _yandexAd;
  bool _yandexFailed = false;

  @override
  void initState() {
    super.initState();
    _loadAd();
  }

  @override
  void dispose() {
    _ad?.dispose();
    super.dispose();
  }

  void _loadAd() {
    if (!Platform.isAndroid && !Platform.isIOS) return;

    final unitId = widget.adUnitId.isNotEmpty
        ? widget.adUnitId
        : (kDebugMode ? _testBannerAdUnit : '');

    if (unitId.isEmpty) {
      // No AdMob unit configured for this build → go straight to Yandex.
      _loadYandex();
      return;
    }

    BannerAd(
      adUnitId: unitId,
      size: AdSize.banner,
      request: const AdRequest(),
      listener: BannerAdListener(
        onAdLoaded: (ad) {
          if (!mounted) {
            ad.dispose();
            return;
          }
          setState(() {
            _ad = ad as BannerAd;
            _loaded = true;
          });
        },
        onAdFailedToLoad: (ad, error) {
          ad.dispose();
          // AdMob has no fill → fall back to Yandex.
          debugPrint('AdMob banner failed (${error.code}), trying Yandex');
          _loadYandex();
        },
      ),
    ).load();
  }

  /// Builds the Yandex banner; its platform view auto-loads on creation, so we
  /// just render it and react to its load callbacks.
  void _loadYandex() {
    if (!mounted || _yandexAd != null || _yandexFailed) return;
    if (!Platform.isAndroid && !Platform.isIOS) return;

    final unit = kDebugMode ? _demoYandexBannerUnit : _prodYandexBannerUnit;
    final width = MediaQuery.of(context).size.width.truncate();

    final banner = yandex.BannerAd(
      adUnitId: unit,
      adSize: yandex.BannerAdSize.inline(
        width: width,
        maxHeight: widget.height.truncate(),
      ),
      onAdFailedToLoad: (error) {
        debugPrint('Yandex banner failed: ${error.code} ${error.description}');
        if (mounted) setState(() => _yandexFailed = true);
      },
    );
    setState(() => _yandexAd = banner);
  }

  @override
  Widget build(BuildContext context) {
    if (_loaded && _ad != null) {
      return Container(
        height: widget.height,
        alignment: Alignment.center,
        child: AdWidget(ad: _ad!),
      );
    }
    if (_yandexAd != null && !_yandexFailed) {
      return Container(
        height: widget.height,
        alignment: Alignment.center,
        child: yandex.AdWidget(bannerAd: _yandexAd!),
      );
    }
    if (kDebugMode && _errorText != null) {
      return Container(
        height: widget.height,
        color: Colors.red.shade100,
        alignment: Alignment.center,
        child: Text(_errorText!, style: const TextStyle(fontSize: 10, color: Colors.red)),
      );
    }
    return const SizedBox.shrink();
  }
}
