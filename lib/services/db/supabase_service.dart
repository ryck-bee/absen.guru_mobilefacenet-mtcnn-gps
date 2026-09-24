import 'package:supabase_flutter/supabase_flutter.dart';

class SupabaseService {
  static final SupabaseService _instance = SupabaseService._internal();
  factory SupabaseService() => _instance;
  SupabaseService._internal();

  final SupabaseClient _client = Supabase.instance.client;
  SupabaseClient get client => _client;

  static const String emailDomain = 'gubrih.sdn';

  bool get isLoggedIn => _client.auth.currentUser != null;
  User? get currentUser => _client.auth.currentUser;
  Stream<AuthState> get authStateChanges => _client.auth.onAuthStateChange;

  /// Ubah input user (NIP atau email) jadi email yang valid.
  /// Kalau sudah ada "@" -> pakai langsung.
  /// Kalau tidak -> asumsikan NIP, tambah @gubrih.sdn
  String _normalizeIdentifier(String input) {
    final trimmed = input.trim();
    if (trimmed.contains('@')) return trimmed;
    return '$trimmed@$emailDomain';
  }

  Future<AuthResponse> signIn({
    required String identifier,
    required String password,
  }) async {
    final email = _normalizeIdentifier(identifier);
    return await _client.auth.signInWithPassword(
      email: email,
      password: password,
    );
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
  }

    /// Ambil profil dari tabel profiles
  Future<Map<String, dynamic>?> getProfile() async {
    final user = _client.auth.currentUser;
    if (user == null) return null;

    final data = await _client
        .from('profiles')
        .select()
        .eq('id', user.id)
        .maybeSingle();
    return data;
  }

  /// Ambil info sekolah (SDN Gubrih 1)
  Future<Map<String, dynamic>?> getSekolah() async {
    final data = await _client
        .from('sekolah')
        .select()
        .eq('id', 'SDN_GUBRIH_1')
        .maybeSingle();
    return data;
  }
}