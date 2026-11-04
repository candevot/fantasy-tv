import 'package:flutter/material.dart';
class FullPlayerPage extends StatelessWidget {
  const FullPlayerPage({super.key, this.videoId = '', this.ep = 1, this.line = ''});
  final String videoId; final int ep; final String line;
  @override
  Widget build(BuildContext context) => const Center(child: Text('FullPlayerPage'));
}
