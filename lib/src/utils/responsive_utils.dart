import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

enum DeviceType { phone, tablet, desktop }

enum ScreenSizeType { compact, medium, expanded }

class DeviceSpecs {
  final String name;
  final double width;
  final double height;
  final double dpi;
  final double refreshRate;
  final double aspectRatio;

  const DeviceSpecs({
    required this.name,
    required this.width,
    required this.height,
    required this.dpi,
    required this.refreshRate,
    required this.aspectRatio,
  });

  static const huaweiMate9 = DeviceSpecs(
    name: 'HUAWEI Mate 9',
    width: 1080,
    height: 1920,
    dpi: 373,
    refreshRate: 60,
    aspectRatio: 16 / 9,
  );
  static const huaweiMate9Pro = DeviceSpecs(
    name: 'HUAWEI Mate 9 Pro',
    width: 1440,
    height: 2560,
    dpi: 534,
    refreshRate: 60,
    aspectRatio: 16 / 9,
  );
  static const huaweiMate10 = DeviceSpecs(
    name: 'HUAWEI Mate 10',
    width: 1440,
    height: 2560,
    dpi: 498,
    refreshRate: 60,
    aspectRatio: 16 / 9,
  );
  static const huaweiMate10Pro = DeviceSpecs(
    name: 'HUAWEI Mate 10 Pro',
    width: 1080,
    height: 2160,
    dpi: 402,
    refreshRate: 60,
    aspectRatio: 18 / 9,
  );
  static const huaweiMate10Lite = DeviceSpecs(
    name: 'HUAWEI Mate 10 Lite',
    width: 1080,
    height: 2160,
    dpi: 409,
    refreshRate: 60,
    aspectRatio: 18 / 9,
  );
  static const huaweiMate20 = DeviceSpecs(
    name: 'HUAWEI Mate 20',
    width: 1080,
    height: 2244,
    dpi: 381,
    refreshRate: 60,
    aspectRatio: 18.7 / 9,
  );
  static const huaweiMate20Pro = DeviceSpecs(
    name: 'HUAWEI Mate 20 Pro',
    width: 1440,
    height: 3120,
    dpi: 538,
    refreshRate: 60,
    aspectRatio: 19.5 / 9,
  );
  static const huaweiMate20X = DeviceSpecs(
    name: 'HUAWEI Mate 20 X',
    width: 1080,
    height: 2244,
    dpi: 346,
    refreshRate: 60,
    aspectRatio: 18.7 / 9,
  );
  static const huaweiMate20Lite = DeviceSpecs(
    name: 'HUAWEI Mate 20 Lite',
    width: 1080,
    height: 2340,
    dpi: 409,
    refreshRate: 60,
    aspectRatio: 19.5 / 9,
  );
  static const huaweiMate30 = DeviceSpecs(
    name: 'HUAWEI Mate 30',
    width: 1080,
    height: 2400,
    dpi: 409,
    refreshRate: 60,
    aspectRatio: 20 / 9,
  );
  static const huaweiMate30Pro = DeviceSpecs(
    name: 'HUAWEI Mate 30 Pro',
    width: 1176,
    height: 2400,
    dpi: 409,
    refreshRate: 60,
    aspectRatio: 18.4 / 9,
  );
  static const huaweiMate30Pro5G = DeviceSpecs(
    name: 'HUAWEI Mate 30 Pro 5G',
    width: 1176,
    height: 2400,
    dpi: 409,
    refreshRate: 60,
    aspectRatio: 18.4 / 9,
  );
  static const huaweiMate40 = DeviceSpecs(
    name: 'HUAWEI Mate 40',
    width: 1080,
    height: 2376,
    dpi: 409,
    refreshRate: 90,
    aspectRatio: 19.8 / 9,
  );
  static const huaweiMate40Pro = DeviceSpecs(
    name: 'HUAWEI Mate 40 Pro',
    width: 1200,
    height: 2640,
    dpi: 456,
    refreshRate: 90,
    aspectRatio: 19.8 / 9,
  );
  static const huaweiMate40ProPlus = DeviceSpecs(
    name: 'HUAWEI Mate 40 Pro+',
    width: 1200,
    height: 2640,
    dpi: 456,
    refreshRate: 90,
    aspectRatio: 19.8 / 9,
  );
  static const huaweiNova12Pro = DeviceSpecs(
    name: 'Huawei nova 12 Pro',
    width: 1200,
    height: 2676,
    dpi: 460,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );

  static const xiaomi10 = DeviceSpecs(
    name: 'Xiaomi Mi 10',
    width: 1080,
    height: 2340,
    dpi: 386,
    refreshRate: 90,
    aspectRatio: 19.5 / 9,
  );
  static const xiaomi10Pro = DeviceSpecs(
    name: 'Xiaomi Mi 10 Pro',
    width: 1080,
    height: 2340,
    dpi: 386,
    refreshRate: 90,
    aspectRatio: 19.5 / 9,
  );
  static const xiaomi10Ultra = DeviceSpecs(
    name: 'Xiaomi Mi 10 Ultra',
    width: 1080,
    height: 2340,
    dpi: 386,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const xiaomi10Lite = DeviceSpecs(
    name: 'Xiaomi Mi 10 Lite',
    width: 1080,
    height: 2400,
    dpi: 405,
    refreshRate: 60,
    aspectRatio: 20 / 9,
  );
  static const xiaomi11 = DeviceSpecs(
    name: 'Xiaomi Mi 11',
    width: 1440,
    height: 3200,
    dpi: 515,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi11Pro = DeviceSpecs(
    name: 'Xiaomi Mi 11 Pro',
    width: 1440,
    height: 3200,
    dpi: 515,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi11Ultra = DeviceSpecs(
    name: 'Xiaomi Mi 11 Ultra',
    width: 1440,
    height: 3200,
    dpi: 515,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi11Lite = DeviceSpecs(
    name: 'Xiaomi Mi 11 Lite',
    width: 1080,
    height: 2400,
    dpi: 402,
    refreshRate: 90,
    aspectRatio: 20 / 9,
  );
  static const xiaomi12 = DeviceSpecs(
    name: 'Xiaomi 12',
    width: 1080,
    height: 2400,
    dpi: 419,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi12Pro = DeviceSpecs(
    name: 'Xiaomi 12 Pro',
    width: 1440,
    height: 3200,
    dpi: 522,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi12Ultra = DeviceSpecs(
    name: 'Xiaomi 12S Ultra',
    width: 1440,
    height: 3200,
    dpi: 522,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi12Lite = DeviceSpecs(
    name: 'Xiaomi 12 Lite',
    width: 1080,
    height: 2400,
    dpi: 402,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi13 = DeviceSpecs(
    name: 'Xiaomi 13',
    width: 1080,
    height: 2400,
    dpi: 401,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi13Pro = DeviceSpecs(
    name: 'Xiaomi 13 Pro',
    width: 1440,
    height: 3200,
    dpi: 522,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi13Ultra = DeviceSpecs(
    name: 'Xiaomi 13 Ultra',
    width: 1440,
    height: 3200,
    dpi: 522,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi13Lite = DeviceSpecs(
    name: 'Xiaomi 13 Lite',
    width: 1080,
    height: 2400,
    dpi: 402,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi14 = DeviceSpecs(
    name: 'Xiaomi 14',
    width: 1200,
    height: 2670,
    dpi: 460,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi14Pro = DeviceSpecs(
    name: 'Xiaomi 14 Pro',
    width: 1440,
    height: 3200,
    dpi: 522,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi14Ultra = DeviceSpecs(
    name: 'Xiaomi 14 Ultra',
    width: 1440,
    height: 3200,
    dpi: 522,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi15 = DeviceSpecs(
    name: 'Xiaomi 15',
    width: 1200,
    height: 2670,
    dpi: 460,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi15Pro = DeviceSpecs(
    name: 'Xiaomi 15 Pro',
    width: 1440,
    height: 3200,
    dpi: 522,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi15Ultra = DeviceSpecs(
    name: 'Xiaomi 15 Ultra',
    width: 1440,
    height: 3200,
    dpi: 525,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi17 = DeviceSpecs(
    name: 'Xiaomi 17',
    width: 1260,
    height: 2800,
    dpi: 470,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const xiaomi17Pro = DeviceSpecs(
    name: 'Xiaomi 17 Pro',
    width: 1440,
    height: 3200,
    dpi: 530,
    refreshRate: 144,
    aspectRatio: 20 / 9,
  );
  static const xiaomi17Ultra = DeviceSpecs(
    name: 'Xiaomi 17 Ultra',
    width: 1440,
    height: 3200,
    dpi: 535,
    refreshRate: 144,
    aspectRatio: 20 / 9,
  );

  static const onePlus12 = DeviceSpecs(
    name: 'OnePlus 12',
    width: 1440,
    height: 3168,
    dpi: 510,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const onePlus12R = DeviceSpecs(
    name: 'OnePlus 12R',
    width: 1264,
    height: 2780,
    dpi: 450,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const onePlus13 = DeviceSpecs(
    name: 'OnePlus 13',
    width: 1440,
    height: 3168,
    dpi: 510,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const onePlus13R = DeviceSpecs(
    name: 'OnePlus 13R',
    width: 1264,
    height: 2780,
    dpi: 450,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const onePlus14 = DeviceSpecs(
    name: 'OnePlus 14',
    width: 1440,
    height: 3200,
    dpi: 520,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const onePlus15 = DeviceSpecs(
    name: 'OnePlus 15',
    width: 1440,
    height: 3216,
    dpi: 525,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const onePlusAce3 = DeviceSpecs(
    name: 'OnePlus Ace 3',
    width: 1264,
    height: 2780,
    dpi: 450,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const onePlusAce3Pro = DeviceSpecs(
    name: 'OnePlus Ace 3 Pro',
    width: 1264,
    height: 2780,
    dpi: 450,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const onePlusAce3V = DeviceSpecs(
    name: 'OnePlus Ace 3V',
    width: 1080,
    height: 2412,
    dpi: 394,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const onePlusAce5 = DeviceSpecs(
    name: 'OnePlus Ace 5',
    width: 1264,
    height: 2780,
    dpi: 450,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const onePlusAce5Pro = DeviceSpecs(
    name: 'OnePlus Ace 5 Pro',
    width: 1440,
    height: 3168,
    dpi: 510,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const onePlusAce6 = DeviceSpecs(
    name: 'OnePlus Ace 6',
    width: 1264,
    height: 2780,
    dpi: 452,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const onePlusAce6T = DeviceSpecs(
    name: 'OnePlus Ace 6T',
    width: 1264,
    height: 2780,
    dpi: 455,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );

  static const vivoX100 = DeviceSpecs(
    name: 'Vivo X100',
    width: 1260,
    height: 2800,
    dpi: 452,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const vivoX100Pro = DeviceSpecs(
    name: 'Vivo X100 Pro',
    width: 1440,
    height: 3200,
    dpi: 510,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const vivoX100Ultra = DeviceSpecs(
    name: 'Vivo X100 Ultra',
    width: 1440,
    height: 3200,
    dpi: 510,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const vivoX100s = DeviceSpecs(
    name: 'Vivo X100s',
    width: 1260,
    height: 2800,
    dpi: 452,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const vivoX100sPro = DeviceSpecs(
    name: 'Vivo X100s Pro',
    width: 1440,
    height: 3200,
    dpi: 510,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const vivoX200 = DeviceSpecs(
    name: 'Vivo X200',
    width: 1260,
    height: 2800,
    dpi: 452,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const vivoX200Pro = DeviceSpecs(
    name: 'Vivo X200 Pro',
    width: 1440,
    height: 3200,
    dpi: 510,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const vivoX200ProMini = DeviceSpecs(
    name: 'Vivo X200 Pro Mini',
    width: 1260,
    height: 2800,
    dpi: 460,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const vivoX200Ultra = DeviceSpecs(
    name: 'Vivo X200 Ultra',
    width: 1440,
    height: 3200,
    dpi: 515,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );

  static const oppoFindX7 = DeviceSpecs(
    name: 'OPPO Find X7',
    width: 1264,
    height: 2780,
    dpi: 452,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const oppoFindX7Ultra = DeviceSpecs(
    name: 'OPPO Find X7 Ultra',
    width: 1440,
    height: 3168,
    dpi: 510,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const oppoFindX8 = DeviceSpecs(
    name: 'OPPO Find X8',
    width: 1264,
    height: 2780,
    dpi: 452,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const oppoFindX8Pro = DeviceSpecs(
    name: 'OPPO Find X8 Pro',
    width: 1440,
    height: 3168,
    dpi: 510,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const oppoFindN3 = DeviceSpecs(
    name: 'OPPO Find N3',
    width: 1440,
    height: 2120,
    dpi: 426,
    refreshRate: 120,
    aspectRatio: 20.4 / 9,
  );
  static const oppoFindN3Flip = DeviceSpecs(
    name: 'OPPO Find N3 Flip',
    width: 1080,
    height: 2520,
    dpi: 403,
    refreshRate: 120,
    aspectRatio: 21 / 9,
  );

  static const samsungS20 = DeviceSpecs(
    name: 'Samsung Galaxy S20',
    width: 1440,
    height: 3200,
    dpi: 563,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const samsungS20Plus = DeviceSpecs(
    name: 'Samsung Galaxy S20+',
    width: 1440,
    height: 3200,
    dpi: 525,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const samsungS20Ultra = DeviceSpecs(
    name: 'Samsung Galaxy S20 Ultra',
    width: 1440,
    height: 3200,
    dpi: 511,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const samsungS20FE = DeviceSpecs(
    name: 'Samsung Galaxy S20 FE',
    width: 1080,
    height: 2400,
    dpi: 407,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const samsungS21 = DeviceSpecs(
    name: 'Samsung Galaxy S21',
    width: 1080,
    height: 2400,
    dpi: 421,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const samsungS21Plus = DeviceSpecs(
    name: 'Samsung Galaxy S21+',
    width: 1080,
    height: 2400,
    dpi: 394,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const samsungS21Ultra = DeviceSpecs(
    name: 'Samsung Galaxy S21 Ultra',
    width: 1440,
    height: 3200,
    dpi: 515,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const samsungS21FE = DeviceSpecs(
    name: 'Samsung Galaxy S21 FE',
    width: 1080,
    height: 2340,
    dpi: 401,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS22 = DeviceSpecs(
    name: 'Samsung Galaxy S22',
    width: 1080,
    height: 2340,
    dpi: 425,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS22Plus = DeviceSpecs(
    name: 'Samsung Galaxy S22+',
    width: 1080,
    height: 2340,
    dpi: 393,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS22Ultra = DeviceSpecs(
    name: 'Samsung Galaxy S22 Ultra',
    width: 1440,
    height: 3088,
    dpi: 500,
    refreshRate: 120,
    aspectRatio: 19.3 / 9,
  );
  static const samsungS23 = DeviceSpecs(
    name: 'Samsung Galaxy S23',
    width: 1080,
    height: 2340,
    dpi: 425,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS23Plus = DeviceSpecs(
    name: 'Samsung Galaxy S23+',
    width: 1080,
    height: 2340,
    dpi: 393,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS23Ultra = DeviceSpecs(
    name: 'Samsung Galaxy S23 Ultra',
    width: 1440,
    height: 3088,
    dpi: 500,
    refreshRate: 120,
    aspectRatio: 19.3 / 9,
  );
  static const samsungS23FE = DeviceSpecs(
    name: 'Samsung Galaxy S23 FE',
    width: 1080,
    height: 2340,
    dpi: 401,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS24 = DeviceSpecs(
    name: 'Samsung Galaxy S24',
    width: 1080,
    height: 2340,
    dpi: 416,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS24Plus = DeviceSpecs(
    name: 'Samsung Galaxy S24+',
    width: 1440,
    height: 3120,
    dpi: 513,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS24Ultra = DeviceSpecs(
    name: 'Samsung Galaxy S24 Ultra',
    width: 1440,
    height: 3120,
    dpi: 505,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS24FE = DeviceSpecs(
    name: 'Samsung Galaxy S24 FE',
    width: 1080,
    height: 2340,
    dpi: 385,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS25 = DeviceSpecs(
    name: 'Samsung Galaxy S25',
    width: 1080,
    height: 2340,
    dpi: 416,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS25Plus = DeviceSpecs(
    name: 'Samsung Galaxy S25+',
    width: 1440,
    height: 3120,
    dpi: 513,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS25Ultra = DeviceSpecs(
    name: 'Samsung Galaxy S25 Ultra',
    width: 1440,
    height: 3120,
    dpi: 498,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const samsungS25Edge = DeviceSpecs(
    name: 'Samsung Galaxy S25 Edge',
    width: 1440,
    height: 3120,
    dpi: 513,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );

  static const samsungNote20 = DeviceSpecs(
    name: 'Samsung Galaxy Note 20',
    width: 1080,
    height: 2400,
    dpi: 393,
    refreshRate: 60,
    aspectRatio: 20 / 9,
  );
  static const samsungNote20Ultra = DeviceSpecs(
    name: 'Samsung Galaxy Note 20 Ultra',
    width: 1440,
    height: 3088,
    dpi: 496,
    refreshRate: 120,
    aspectRatio: 19.3 / 9,
  );

  static const nothingPhone1 = DeviceSpecs(
    name: 'Nothing Phone (1)',
    width: 1080,
    height: 2400,
    dpi: 402,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const nothingPhone2 = DeviceSpecs(
    name: 'Nothing Phone (2)',
    width: 1080,
    height: 2412,
    dpi: 394,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const nothingPhone2a = DeviceSpecs(
    name: 'Nothing Phone (2a)',
    width: 1080,
    height: 2412,
    dpi: 394,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const nothingPhone2aPlus = DeviceSpecs(
    name: 'Nothing Phone (2a) Plus',
    width: 1080,
    height: 2412,
    dpi: 394,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const nothingPhone3 = DeviceSpecs(
    name: 'Nothing Phone (3)',
    width: 1264,
    height: 2780,
    dpi: 450,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const nothingPhone3a = DeviceSpecs(
    name: 'Nothing Phone (3a)',
    width: 1080,
    height: 2412,
    dpi: 398,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const nothingPhone3aPro = DeviceSpecs(
    name: 'Nothing Phone (3a) Pro',
    width: 1080,
    height: 2412,
    dpi: 398,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );

  static const realme8 = DeviceSpecs(
    name: 'Realme 8',
    width: 1080,
    height: 2400,
    dpi: 405,
    refreshRate: 60,
    aspectRatio: 20 / 9,
  );
  static const realme8Pro = DeviceSpecs(
    name: 'Realme 8 Pro',
    width: 1080,
    height: 2400,
    dpi: 405,
    refreshRate: 60,
    aspectRatio: 20 / 9,
  );
  static const realme85G = DeviceSpecs(
    name: 'Realme 8 5G',
    width: 1080,
    height: 2400,
    dpi: 405,
    refreshRate: 90,
    aspectRatio: 20 / 9,
  );
  static const realme8i = DeviceSpecs(
    name: 'Realme 8i',
    width: 1080,
    height: 2400,
    dpi: 400,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const realme8s5G = DeviceSpecs(
    name: 'Realme 8s 5G',
    width: 1080,
    height: 2400,
    dpi: 405,
    refreshRate: 90,
    aspectRatio: 20 / 9,
  );
  static const realme9 = DeviceSpecs(
    name: 'Realme 9',
    width: 1080,
    height: 2400,
    dpi: 409,
    refreshRate: 90,
    aspectRatio: 20 / 9,
  );
  static const realme9Pro = DeviceSpecs(
    name: 'Realme 9 Pro',
    width: 1080,
    height: 2400,
    dpi: 405,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const realme9ProPlus = DeviceSpecs(
    name: 'Realme 9 Pro+',
    width: 1080,
    height: 2400,
    dpi: 409,
    refreshRate: 90,
    aspectRatio: 20 / 9,
  );
  static const realme95G = DeviceSpecs(
    name: 'Realme 9 5G',
    width: 1080,
    height: 2400,
    dpi: 405,
    refreshRate: 90,
    aspectRatio: 20 / 9,
  );
  static const realme9i = DeviceSpecs(
    name: 'Realme 9i',
    width: 1080,
    height: 2412,
    dpi: 409,
    refreshRate: 90,
    aspectRatio: 20.1 / 9,
  );
  static const realme10 = DeviceSpecs(
    name: 'Realme 10',
    width: 1080,
    height: 2400,
    dpi: 409,
    refreshRate: 90,
    aspectRatio: 20 / 9,
  );
  static const realme10Pro = DeviceSpecs(
    name: 'Realme 10 Pro',
    width: 1080,
    height: 2400,
    dpi: 394,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const realme10ProPlus = DeviceSpecs(
    name: 'Realme 10 Pro+',
    width: 1080,
    height: 2412,
    dpi: 394,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const realme11 = DeviceSpecs(
    name: 'Realme 11',
    width: 1080,
    height: 2400,
    dpi: 409,
    refreshRate: 90,
    aspectRatio: 20 / 9,
  );
  static const realme11Pro = DeviceSpecs(
    name: 'Realme 11 Pro',
    width: 1080,
    height: 2412,
    dpi: 394,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const realme11ProPlus = DeviceSpecs(
    name: 'Realme 11 Pro+',
    width: 1080,
    height: 2412,
    dpi: 394,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const realme11x = DeviceSpecs(
    name: 'Realme 11x',
    width: 1080,
    height: 2400,
    dpi: 405,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const realme12 = DeviceSpecs(
    name: 'Realme 12',
    width: 1080,
    height: 2400,
    dpi: 409,
    refreshRate: 90,
    aspectRatio: 20 / 9,
  );
  static const realme12Pro = DeviceSpecs(
    name: 'Realme 12 Pro',
    width: 1080,
    height: 2412,
    dpi: 394,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const realme12ProPlus = DeviceSpecs(
    name: 'Realme 12 Pro+',
    width: 1220,
    height: 2712,
    dpi: 448,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const realme12x = DeviceSpecs(
    name: 'Realme 12x',
    width: 1080,
    height: 2400,
    dpi: 405,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const realme125G = DeviceSpecs(
    name: 'Realme 12 5G',
    width: 1080,
    height: 2400,
    dpi: 405,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const realme13 = DeviceSpecs(
    name: 'Realme 13',
    width: 1080,
    height: 2400,
    dpi: 409,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const realme13Pro = DeviceSpecs(
    name: 'Realme 13 Pro',
    width: 1080,
    height: 2412,
    dpi: 394,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const realme13ProPlus = DeviceSpecs(
    name: 'Realme 13 Pro+',
    width: 1264,
    height: 2780,
    dpi: 450,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const realme135G = DeviceSpecs(
    name: 'Realme 13 5G',
    width: 1080,
    height: 2400,
    dpi: 405,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const realmeGT5 = DeviceSpecs(
    name: 'Realme GT 5',
    width: 1264,
    height: 2780,
    dpi: 450,
    refreshRate: 144,
    aspectRatio: 19.8 / 9,
  );
  static const realmeGT5Pro = DeviceSpecs(
    name: 'Realme GT 5 Pro',
    width: 1264,
    height: 2780,
    dpi: 450,
    refreshRate: 144,
    aspectRatio: 19.8 / 9,
  );
  static const realmeGT6 = DeviceSpecs(
    name: 'Realme GT 6',
    width: 1264,
    height: 2780,
    dpi: 450,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );
  static const realmeGT6T = DeviceSpecs(
    name: 'Realme GT 6T',
    width: 1264,
    height: 2780,
    dpi: 450,
    refreshRate: 120,
    aspectRatio: 19.8 / 9,
  );

  static const pixel5 = DeviceSpecs(
    name: 'Pixel 5',
    width: 1080,
    height: 2340,
    dpi: 432,
    refreshRate: 90,
    aspectRatio: 19.5 / 9,
  );
  static const pixel6 = DeviceSpecs(
    name: 'Pixel 6',
    width: 1080,
    height: 2400,
    dpi: 411,
    refreshRate: 90,
    aspectRatio: 20 / 9,
  );
  static const pixel6Pro = DeviceSpecs(
    name: 'Pixel 6 Pro',
    width: 1440,
    height: 3120,
    dpi: 512,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const pixel7 = DeviceSpecs(
    name: 'Pixel 7',
    width: 1080,
    height: 2400,
    dpi: 416,
    refreshRate: 90,
    aspectRatio: 20 / 9,
  );
  static const pixel7Pro = DeviceSpecs(
    name: 'Pixel 7 Pro',
    width: 1440,
    height: 3120,
    dpi: 512,
    refreshRate: 120,
    aspectRatio: 19.5 / 9,
  );
  static const pixel8 = DeviceSpecs(
    name: 'Pixel 8',
    width: 1080,
    height: 2400,
    dpi: 428,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const pixel8Pro = DeviceSpecs(
    name: 'Pixel 8 Pro',
    width: 1344,
    height: 2992,
    dpi: 489,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const pixel9 = DeviceSpecs(
    name: 'Pixel 9',
    width: 1080,
    height: 2424,
    dpi: 422,
    refreshRate: 120,
    aspectRatio: 20.2 / 9,
  );
  static const pixel9Pro = DeviceSpecs(
    name: 'Pixel 9 Pro',
    width: 1280,
    height: 2856,
    dpi: 495,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const pixel9ProXL = DeviceSpecs(
    name: 'Pixel 9 Pro XL',
    width: 1344,
    height: 2992,
    dpi: 486,
    refreshRate: 120,
    aspectRatio: 20.1 / 9,
  );
  static const pixel10 = DeviceSpecs(
    name: 'Pixel 10',
    width: 1080,
    height: 2400,
    dpi: 420,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );
  static const pixel10Pro = DeviceSpecs(
    name: 'Pixel 10 Pro',
    width: 1344,
    height: 3024,
    dpi: 500,
    refreshRate: 120,
    aspectRatio: 20.3 / 9,
  );
  static const pixel10ProXL = DeviceSpecs(
    name: 'Pixel 10 Pro XL',
    width: 1440,
    height: 3200,
    dpi: 510,
    refreshRate: 120,
    aspectRatio: 20 / 9,
  );

  static List<DeviceSpecs> get allDevices => [
    huaweiMate9,
    huaweiMate9Pro,
    huaweiMate10,
    huaweiMate10Pro,
    huaweiMate10Lite,
    huaweiMate20,
    huaweiMate20Pro,
    huaweiMate20X,
    huaweiMate20Lite,
    huaweiMate30,
    huaweiMate30Pro,
    huaweiMate30Pro5G,
    huaweiMate40,
    huaweiMate40Pro,
    huaweiMate40ProPlus,
    huaweiNova12Pro,

    xiaomi10,
    xiaomi10Pro,
    xiaomi10Ultra,
    xiaomi10Lite,
    xiaomi11,
    xiaomi11Pro,
    xiaomi11Ultra,
    xiaomi11Lite,
    xiaomi12,
    xiaomi12Pro,
    xiaomi12Ultra,
    xiaomi12Lite,
    xiaomi13,
    xiaomi13Pro,
    xiaomi13Ultra,
    xiaomi13Lite,
    xiaomi14,
    xiaomi14Pro,
    xiaomi14Ultra,
    xiaomi15,
    xiaomi15Pro,
    xiaomi15Ultra,
    xiaomi17,
    xiaomi17Pro,
    xiaomi17Ultra,

    onePlus12,
    onePlus12R,
    onePlus13,
    onePlus13R,
    onePlus14,
    onePlus15,
    onePlusAce3,
    onePlusAce3Pro,
    onePlusAce3V,
    onePlusAce5,
    onePlusAce5Pro,
    onePlusAce6,
    onePlusAce6T,

    vivoX100,
    vivoX100Pro,
    vivoX100Ultra,
    vivoX100s,
    vivoX100sPro,
    vivoX200,
    vivoX200Pro,
    vivoX200ProMini,
    vivoX200Ultra,

    oppoFindX7,
    oppoFindX7Ultra,
    oppoFindX8,
    oppoFindX8Pro,
    oppoFindN3,
    oppoFindN3Flip,

    samsungS20,
    samsungS20Plus,
    samsungS20Ultra,
    samsungS20FE,
    samsungS21,
    samsungS21Plus,
    samsungS21Ultra,
    samsungS21FE,
    samsungS22,
    samsungS22Plus,
    samsungS22Ultra,
    samsungS23,
    samsungS23Plus,
    samsungS23Ultra,
    samsungS23FE,
    samsungS24,
    samsungS24Plus,
    samsungS24Ultra,
    samsungS24FE,
    samsungS25,
    samsungS25Plus,
    samsungS25Ultra,
    samsungS25Edge,

    samsungNote20,
    samsungNote20Ultra,

    nothingPhone1,
    nothingPhone2,
    nothingPhone2a,
    nothingPhone2aPlus,
    nothingPhone3,
    nothingPhone3a,
    nothingPhone3aPro,

    realme8,
    realme8Pro,
    realme85G,
    realme8i,
    realme8s5G,
    realme9,
    realme9Pro,
    realme9ProPlus,
    realme95G,
    realme9i,
    realme10,
    realme10Pro,
    realme10ProPlus,
    realme11,
    realme11Pro,
    realme11ProPlus,
    realme11x,
    realme12,
    realme12Pro,
    realme12ProPlus,
    realme12x,
    realme125G,
    realme13,
    realme13Pro,
    realme13ProPlus,
    realme135G,
    realmeGT5,
    realmeGT5Pro,
    realmeGT6,
    realmeGT6T,

    pixel5,
    pixel6,
    pixel6Pro,
    pixel7,
    pixel7Pro,
    pixel8,
    pixel8Pro,
    pixel9,
    pixel9Pro,
    pixel9ProXL,
    pixel10,
    pixel10Pro,
    pixel10ProXL,
  ];
}

class ResponsiveUtils {
  ResponsiveUtils._();

  static DeviceType getDeviceType(BuildContext context) {
    final width = MediaQuery.of(context).size.shortestSide;
    if (width < 600) return DeviceType.phone;
    if (width < 900) return DeviceType.tablet;
    return DeviceType.desktop;
  }

  static ScreenSizeType getScreenSizeType(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width < 600) return ScreenSizeType.compact;
    if (width < 840) return ScreenSizeType.medium;
    return ScreenSizeType.expanded;
  }

  static bool isHighDpiDevice(BuildContext context) {
    return MediaQuery.of(context).devicePixelRatio > 2.5;
  }

  static bool isUltraHighDpiDevice(BuildContext context) {
    return MediaQuery.of(context).devicePixelRatio > 3.0;
  }

  static EdgeInsets getSafeAreaPadding(BuildContext context) {
    return MediaQuery.of(context).padding;
  }

  static EdgeInsets getViewPadding(BuildContext context) {
    return MediaQuery.of(context).viewPadding;
  }

  static double getAspectRatio(BuildContext context) {
    final size = MediaQuery.of(context).size;
    return size.height / size.width;
  }

  static bool isTallScreen(BuildContext context) {
    return getAspectRatio(context) > 2.0;
  }

  static bool isExtraTallScreen(BuildContext context) {
    return getAspectRatio(context) > 2.1;
  }

  static EdgeInsets getResponsivePadding(BuildContext context) {
    final screenType = getScreenSizeType(context);
    final safeArea = getSafeAreaPadding(context);

    switch (screenType) {
      case ScreenSizeType.compact:
        return EdgeInsets.fromLTRB(
          16 + safeArea.left,
          8,
          16 + safeArea.right,
          8 + safeArea.bottom,
        );
      case ScreenSizeType.medium:
        return EdgeInsets.fromLTRB(
          24 + safeArea.left,
          12,
          24 + safeArea.right,
          12 + safeArea.bottom,
        );
      case ScreenSizeType.expanded:
        return EdgeInsets.fromLTRB(
          32 + safeArea.left,
          16,
          32 + safeArea.right,
          16 + safeArea.bottom,
        );
    }
  }

  static EdgeInsets getCardPadding(BuildContext context) {
    final screenType = getScreenSizeType(context);
    switch (screenType) {
      case ScreenSizeType.compact:
        return const EdgeInsets.all(12);
      case ScreenSizeType.medium:
        return const EdgeInsets.all(16);
      case ScreenSizeType.expanded:
        return const EdgeInsets.all(20);
    }
  }

  static double getListItemHeight(BuildContext context) {
    final screenType = getScreenSizeType(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);

    double baseHeight;
    switch (screenType) {
      case ScreenSizeType.compact:
        baseHeight = 56;
        break;
      case ScreenSizeType.medium:
        baseHeight = 64;
        break;
      case ScreenSizeType.expanded:
        baseHeight = 72;
        break;
    }

    return baseHeight * (textScale > 1.0 ? (1 + (textScale - 1) * 0.5) : 1.0);
  }

  static double getIconSize(BuildContext context, {bool large = false}) {
    final screenType = getScreenSizeType(context);
    final dpr = MediaQuery.of(context).devicePixelRatio;

    double baseSize;
    switch (screenType) {
      case ScreenSizeType.compact:
        baseSize = large ? 28 : 22;
        break;
      case ScreenSizeType.medium:
        baseSize = large ? 32 : 24;
        break;
      case ScreenSizeType.expanded:
        baseSize = large ? 36 : 28;
        break;
    }

    if (dpr > 3.0) {
      baseSize *= 1.05;
    }

    return baseSize;
  }

  static double getFontScaleFactor(BuildContext context) {
    final screenType = getScreenSizeType(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);

    double baseFactor;
    switch (screenType) {
      case ScreenSizeType.compact:
        baseFactor = 1.0;
        break;
      case ScreenSizeType.medium:
        baseFactor = 1.05;
        break;
      case ScreenSizeType.expanded:
        baseFactor = 1.1;
        break;
    }

    return (baseFactor * textScale).clamp(0.8, 1.5);
  }

  static int getGridColumnCount(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width < 400) return 1;
    if (width < 600) return 2;
    if (width < 900) return 3;
    if (width < 1200) return 4;
    return 5;
  }

  static int getCardGridColumnCount(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    if (width < 500) return 1;
    if (width < 800) return 2;
    if (width < 1100) return 3;
    return 4;
  }

  static double getBorderRadius(BuildContext context) {
    final screenType = getScreenSizeType(context);
    switch (screenType) {
      case ScreenSizeType.compact:
        return 12;
      case ScreenSizeType.medium:
        return 16;
      case ScreenSizeType.expanded:
        return 20;
    }
  }

  static BorderRadius getCardBorderRadius(BuildContext context) {
    return BorderRadius.circular(getBorderRadius(context));
  }

  static double getButtonHeight(BuildContext context) {
    final screenType = getScreenSizeType(context);
    switch (screenType) {
      case ScreenSizeType.compact:
        return 44;
      case ScreenSizeType.medium:
        return 48;
      case ScreenSizeType.expanded:
        return 52;
    }
  }

  static double getInputHeight(BuildContext context) {
    final screenType = getScreenSizeType(context);
    final textScale = MediaQuery.textScalerOf(context).scale(1.0);

    double baseHeight;
    switch (screenType) {
      case ScreenSizeType.compact:
        baseHeight = 48;
        break;
      case ScreenSizeType.medium:
        baseHeight = 52;
        break;
      case ScreenSizeType.expanded:
        baseHeight = 56;
        break;
    }

    return baseHeight * (textScale > 1.0 ? (1 + (textScale - 1) * 0.3) : 1.0);
  }

  static double getBottomNavHeight(BuildContext context) {
    final safeArea = getSafeAreaPadding(context);
    final screenType = getScreenSizeType(context);

    double baseHeight;
    switch (screenType) {
      case ScreenSizeType.compact:
        baseHeight = 64;
        break;
      case ScreenSizeType.medium:
        baseHeight = 72;
        break;
      case ScreenSizeType.expanded:
        baseHeight = 80;
        break;
    }

    return baseHeight + safeArea.bottom;
  }

  static double getAppBarHeight(BuildContext context) {
    final safeArea = getSafeAreaPadding(context);
    final screenType = getScreenSizeType(context);

    double baseHeight;
    switch (screenType) {
      case ScreenSizeType.compact:
        baseHeight = 56;
        break;
      case ScreenSizeType.medium:
        baseHeight = 60;
        break;
      case ScreenSizeType.expanded:
        baseHeight = 64;
        break;
    }

    return baseHeight + safeArea.top;
  }

  static double getDialogMaxWidth(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final screenType = getScreenSizeType(context);

    switch (screenType) {
      case ScreenSizeType.compact:
        return width * 0.92;
      case ScreenSizeType.medium:
        return width * 0.75;
      case ScreenSizeType.expanded:
        return 560;
    }
  }

  static double getBottomSheetMaxHeightRatio(BuildContext context) {
    final aspectRatio = getAspectRatio(context);

    if (aspectRatio > 2.1) return 0.85;
    if (aspectRatio > 2.0) return 0.80;
    if (aspectRatio > 1.8) return 0.75;
    return 0.70;
  }

  static double getSpacing(BuildContext context, {double multiplier = 1.0}) {
    final screenType = getScreenSizeType(context);

    double baseSpacing;
    switch (screenType) {
      case ScreenSizeType.compact:
        baseSpacing = 8;
        break;
      case ScreenSizeType.medium:
        baseSpacing = 12;
        break;
      case ScreenSizeType.expanded:
        baseSpacing = 16;
        break;
    }

    return baseSpacing * multiplier;
  }

  static double getMinTouchTargetSize(BuildContext context) {
    return 48.0;
  }

  static ScrollPhysics getScrollPhysics(BuildContext context) {
    if (!kIsWeb && Platform.isAndroid) {
      return const ClampingScrollPhysics();
    }
    return const BouncingScrollPhysics();
  }

  static bool shouldShowBottomNav(BuildContext context) {
    final screenType = getScreenSizeType(context);
    return screenType == ScreenSizeType.compact;
  }

  static bool shouldShowSideNav(BuildContext context) {
    final screenType = getScreenSizeType(context);
    return screenType != ScreenSizeType.compact;
  }

  static bool shouldShowNavigationRail(BuildContext context) {
    final screenType = getScreenSizeType(context);
    return screenType == ScreenSizeType.medium;
  }

  static bool shouldShowNavigationDrawer(BuildContext context) {
    final screenType = getScreenSizeType(context);
    return screenType == ScreenSizeType.expanded;
  }

  static double getStatusCardHeight(BuildContext context) {
    final screenType = getScreenSizeType(context);
    final isTall = isTallScreen(context);

    double baseHeight;
    switch (screenType) {
      case ScreenSizeType.compact:
        baseHeight = isTall ? 200 : 180;
        break;
      case ScreenSizeType.medium:
        baseHeight = 220;
        break;
      case ScreenSizeType.expanded:
        baseHeight = 240;
        break;
    }

    return baseHeight;
  }

  static double getTrafficChartHeight(BuildContext context) {
    final screenType = getScreenSizeType(context);
    final isTall = isTallScreen(context);

    double baseHeight;
    switch (screenType) {
      case ScreenSizeType.compact:
        baseHeight = isTall ? 180 : 160;
        break;
      case ScreenSizeType.medium:
        baseHeight = 200;
        break;
      case ScreenSizeType.expanded:
        baseHeight = 220;
        break;
    }

    return baseHeight;
  }
}

class ResponsiveBuilder extends StatelessWidget {
  final Widget Function(
    BuildContext context,
    ScreenSizeType screenType,
    DeviceType deviceType,
  )
  builder;

  const ResponsiveBuilder({super.key, required this.builder});

  @override
  Widget build(BuildContext context) {
    return builder(
      context,
      ResponsiveUtils.getScreenSizeType(context),
      ResponsiveUtils.getDeviceType(context),
    );
  }
}

class ResponsiveLayout extends StatelessWidget {
  final Widget compact;
  final Widget? medium;
  final Widget? expanded;

  const ResponsiveLayout({
    super.key,
    required this.compact,
    this.medium,
    this.expanded,
  });

  @override
  Widget build(BuildContext context) {
    final screenType = ResponsiveUtils.getScreenSizeType(context);

    switch (screenType) {
      case ScreenSizeType.expanded:
        return expanded ?? medium ?? compact;
      case ScreenSizeType.medium:
        return medium ?? compact;
      case ScreenSizeType.compact:
        return compact;
    }
  }
}

class ResponsiveSpacing extends StatelessWidget {
  final double multiplier;
  final Axis axis;

  const ResponsiveSpacing({
    super.key,
    this.multiplier = 1.0,
    this.axis = Axis.vertical,
  });

  @override
  Widget build(BuildContext context) {
    final spacing = ResponsiveUtils.getSpacing(context, multiplier: multiplier);

    if (axis == Axis.vertical) {
      return SizedBox(height: spacing);
    } else {
      return SizedBox(width: spacing);
    }
  }
}

class ResponsivePadding extends StatelessWidget {
  final Widget child;
  final double? horizontal;
  final double? vertical;

  const ResponsivePadding({
    super.key,
    required this.child,
    this.horizontal,
    this.vertical,
  });

  @override
  Widget build(BuildContext context) {
    final basePadding = ResponsiveUtils.getResponsivePadding(context);

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: horizontal ?? basePadding.left,
        vertical: vertical ?? basePadding.top,
      ),
      child: child,
    );
  }
}

class SafeAreaWrapper extends StatelessWidget {
  final Widget child;
  final bool top;
  final bool bottom;
  final bool left;
  final bool right;

  const SafeAreaWrapper({
    super.key,
    required this.child,
    this.top = true,
    this.bottom = true,
    this.left = true,
    this.right = true,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      top: top,
      bottom: bottom,
      left: left,
      right: right,
      minimum: EdgeInsets.only(bottom: ResponsiveUtils.getSpacing(context)),
      child: child,
    );
  }
}

class DeviceOptimizedUI {
  DeviceOptimizedUI._();

  static double getBorderRadiusForBrand(BuildContext context, String brand) {
    final baseBorderRadius = ResponsiveUtils.getBorderRadius(context);

    switch (brand.toUpperCase()) {
      case 'SAMSUNG':
        return baseBorderRadius * 1.25;
      case 'XIAOMI':
      case 'REDMI':
      case 'POCO':
        return baseBorderRadius;
      case 'HUAWEI':
      case 'HONOR':
        return baseBorderRadius * 1.1;
      case 'ONEPLUS':
        return baseBorderRadius;
      case 'VIVO':
      case 'IQOO':
        return baseBorderRadius * 0.9;
      case 'OPPO':
      case 'REALME':
        return baseBorderRadius * 0.9;
      case 'NOTHING':
        return baseBorderRadius * 0.75;
      case 'GOOGLE':
        return baseBorderRadius;
      default:
        return baseBorderRadius;
    }
  }

  static List<BoxShadow> getCardShadowForBrand(
    BuildContext context,
    String brand,
    ColorScheme colorScheme,
  ) {
    switch (brand.toUpperCase()) {
      case 'SAMSUNG':
        return [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.08),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ];
      case 'XIAOMI':
      case 'REDMI':
        return [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.12),
            blurRadius: 12,
            offset: const Offset(0, 3),
          ),
        ];
      case 'NOTHING':
        return [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.04),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ];
      default:
        return [
          BoxShadow(
            color: colorScheme.shadow.withValues(alpha: 0.1),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ];
    }
  }

  static Duration getAnimationDurationForBrand(String brand) {
    switch (brand.toUpperCase()) {
      case 'SAMSUNG':
        return const Duration(milliseconds: 350);
      case 'ONEPLUS':
        return const Duration(milliseconds: 250);
      case 'NOTHING':
        return const Duration(milliseconds: 200);
      default:
        return const Duration(milliseconds: 300);
    }
  }

  static double getIconSizeForBrand(BuildContext context, String brand) {
    final baseIconSize = ResponsiveUtils.getIconSize(context);

    switch (brand.toUpperCase()) {
      case 'SAMSUNG':
        return baseIconSize * 1.1;
      case 'NOTHING':
        return baseIconSize * 0.95;
      default:
        return baseIconSize;
    }
  }

  static FontWeight getTitleFontWeightForBrand(String brand) {
    switch (brand.toUpperCase()) {
      case 'SAMSUNG':
        return FontWeight.w600;
      case 'XIAOMI':
        return FontWeight.w500;
      case 'NOTHING':
        return FontWeight.w400;
      default:
        return FontWeight.w600;
    }
  }
}
