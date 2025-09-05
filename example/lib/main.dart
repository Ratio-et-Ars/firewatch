import 'package:firebase_auth/firebase_auth.dart';
import 'package:firewatch/firewatch.dart';
import 'package:flutter/material.dart';
import 'package:injectable/injectable.dart';
import 'package:watch_it/watch_it.dart';

/// A Firestore-backed model must implement JsonModel.
class UserSettings implements JsonModel {
  @override
  final String id;
  final String theme;

  UserSettings({required this.id, required this.theme});

  factory UserSettings.fromJson(Map<String, dynamic> json) => UserSettings(
    id: json['id'] as String, // injected by Firewatch
    theme: json['theme'] as String? ?? 'light',
  );

  @override
  Map<String, dynamic> toJson() => {'theme': theme};
}

/// Repository for getting the user ID
@singleton
class AuthRepository extends ValueNotifier<String?> {
  AuthRepository(this._auth) : super(_auth.currentUser?.uid) {
    _auth.userChanges().listen((user) => value = user?.uid);
  }

  final FirebaseAuth _auth;
}

/// Repository binding the model to Firestore.
@singleton
class UserSettingsRepository extends FirestoreDocRepository<UserSettings> {
  UserSettingsRepository({required AuthRepository auth})
    : super(
        fromJson: UserSettings.fromJson,
        docRefBuilder: (fs, uid) => fs.doc('users/$uid'),
        authUid: auth,
        subscribe: true,
      );
}

/// Example widget consuming the repo with watch_it.
class SettingsPage extends StatelessWidget {
  const SettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    // WatchIt rebuilds when the repo's ValueNotifier changes
    final userSettings = watchIt<UserSettingsRepository>().value;
    final isLoading = watchValue((UserSettingsRepository u) => u.isLoading);

    if (isLoading || userSettings == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: Center(child: Text('Theme: ${userSettings.theme}')),
    );
  }
}
