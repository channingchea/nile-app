import 'dart:io';
import 'package:image/image.dart' as img;

void main() {
  final file = File('assets/images/logo_large_dark.png');
  if (!file.existsSync()) {
    print('Error: assets/images/logo_large.png not found');
    exit(1);
  }

  final bytes = file.readAsBytesSync();
  final image = img.decodeImage(bytes);
  if (image == null) {
    print('Error: could not decode image');
    exit(1);
  }
  
  final int size = image.width > image.height ? image.width : image.height;
  // Add some padding so the logo doesn't touch the edges of the icon
  final int paddedSize = (size * 1.3).round();
  
  // Create solid background image (#181818 = rgb(24, 24, 24))
  final bg = img.Image(width: paddedSize, height: paddedSize, numChannels: 4);
  img.fill(bg, color: img.ColorRgba8(24, 24, 24, 255));
  
  // Create transparent background image for Android adaptive foreground
  final fg = img.Image(width: paddedSize, height: paddedSize, numChannels: 4);
  
  final dstX = (paddedSize - image.width) ~/ 2;
  final dstY = (paddedSize - image.height) ~/ 2;
  
  // Draw logo onto bg
  img.compositeImage(bg, image, dstX: dstX, dstY: dstY);
  File('assets/images/logo_icon.png').writeAsBytesSync(img.encodePng(bg));
  
  // Draw logo onto fg
  img.compositeImage(fg, image, dstX: dstX, dstY: dstY);
  File('assets/images/logo_icon_foreground.png').writeAsBytesSync(img.encodePng(fg));
  
  print('Successfully created padded icons!');
}
