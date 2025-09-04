import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firewatch/firewatch.dart';
import 'package:flutter/foundation.dart';

class UserProfile implements JsonModel {
  @override
  final String id;
  final String displayName;

  UserProfile({required this.id, required this.displayName});

  factory UserProfile.fromJson(Map<String, dynamic> m) => UserProfile(
        id: m['id'] as String,
        displayName: m['displayName'] as String? ?? '',
      );

  @override
  Map<String, dynamic> toJson() => {'displayName': displayName};
}

void main() {
  final authUid = ValueNotifier<String?>(null);

  final docRepo = FirestoreDocRepository<UserProfile>(
    firestore: FirebaseFirestore.instance,
    fromJson: UserProfile.fromJson,
    docRefBuilder: (fs, uid) => fs.doc('users/$uid'),
    authUid: authUid,
    subscribe: true,
  );

  final colRepo = FirestoreCollectionRepository<UserProfile>(
    firestore: FirebaseFirestore.instance,
    fromJson: UserProfile.fromJson,
    colRefBuilder: (fs, uid) => fs.collection('users/$uid/friends'),
    authUid: authUid,
    subscribe: true,
    pageSize: 25,
  );

  // When a user signs in:
  authUid.value = 'abc123';
  // When they sign out:
  // authUid.value = null;

  // Writes:
  docRepo.write(UserProfile(id: 'abc123', displayName: 'Marty'));
  colRepo.add({'displayName': 'Alice'});
}
