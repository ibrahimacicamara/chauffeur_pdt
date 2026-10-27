// import 'dart:typed_data';

// import 'package:firebase_storage/firebase_storage.dart';

// class FireStorageServices {
//   /// Uploads image bytes to Firebase Storage and returns the download URL.
//   static Future<String> uploadImage(
//     Uint8List imageBytes, {
//     required String fileName,
//     String contentType = 'image/jpeg',
//   }) async {
//     final reference = FirebaseStorage.instance.ref().child('images/$fileName');
//     final snapshot = await reference.putData(
//       imageBytes,
//       SettableMetadata(contentType: contentType),
//     );
//     return snapshot.ref.getDownloadURL();
//   }
// }
