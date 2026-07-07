import 'package:flutter/material.dart';

class NileLogo extends StatelessWidget {
  const NileLogo({super.key, required this.size, required this.height});
  
  /// 'large', 'medium', or 'small'
  final String size;
  
  final double height;

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final suffix = isDark ? 'dark' : 'light';
    
    return Image.asset(
      'assets/images/logo_${size}_$suffix.png',
      height: height,
      // Suppress layout shifts if image takes a frame to decode
      errorBuilder: (context, error, stackTrace) => SizedBox(height: height),
    );
  }
}
