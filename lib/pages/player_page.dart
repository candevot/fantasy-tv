import 'package:flutter/material.dart';
class PlayerPage extends StatelessWidget {
  const PlayerPage({super.key, required this.videoId, this.ep = 1, this.line = ''});
  final String videoId; final int ep; final String line;
  @override
  Widget build(BuildContext context) => const Center(child: Text('PlayerPage'));
}
