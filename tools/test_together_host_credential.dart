import '../lib/widgets/together_host_credential.dart';

void check(bool condition, String label) {
  if (!condition) throw StateError(label);
}

void main() {
  final credential = TogetherHostCredential();
  check(!credential.joinPayload('111111').containsKey('hostToken'), 'empty');
  credential.capture('111111', {
    'room': {'code': '222222', 'hostToken': 'fixture'},
  });
  check(!credential.joinPayload('111111').containsKey('hostToken'),
      'reject mismatched room');
  credential.capture('111111', {
    'room': {'code': '111111', 'hostToken': 'fixture'},
  });
  check(credential.joinPayload('111111')['hostToken'] == 'fixture',
      'nested server credential');
  check(!credential.joinPayload('222222').containsKey('hostToken'),
      'never send to another room');
  credential.clear();
  check(!credential.joinPayload('111111').containsKey('hostToken'),
      'clear on leave or switch');
  credential.capture('111111', {
    'room': {'code': '111111'},
    'hostToken': 'fixture-top',
  });
  check(credential.joinPayload('111111')['hostToken'] == 'fixture-top',
      'legacy top-level server credential');
  credential.clear();
  credential.capture('111111', {
    'room': {'code': '111111', 'hostToken': 123},
  });
  check(!credential.joinPayload('111111').containsKey('hostToken'),
      'reject invalid token type');
  print('PASS 7 room-scoped host credential checks');
}
