import 'package:flutter/material.dart';
class TogetherPage extends StatelessWidget {
  const TogetherPage({super.key, this.videoId, this.ep = 1});
  final String? videoId; final int ep;
  @override
  Widget build(BuildContext context) => const Center(child: Text('TogetherPage'));
}
