/// In-memory server-issued host credential, scoped to one room only.
/// Never log or persist this object or its join payload.
class TogetherHostCredential {
  String _code = '';
  String _token = '';

  void clear() {
    _code = '';
    _token = '';
  }

  void capture(String expectedCode, Map<String, dynamic> message) {
    final rawRoom = message['room'];
    if (rawRoom is! Map || rawRoom['code'] != expectedCode) return;
    final rawToken = rawRoom['hostToken'] ?? message['hostToken'];
    if (expectedCode.isEmpty || rawToken is! String || rawToken.isEmpty) return;
    _code = expectedCode;
    _token = rawToken;
  }

  Map<String, dynamic> joinPayload(String code) => <String, dynamic>{
        'action': 'join',
        'code': code,
        if (code == _code && _token.isNotEmpty) 'hostToken': _token,
      };
}
