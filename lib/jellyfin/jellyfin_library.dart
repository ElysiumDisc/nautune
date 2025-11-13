class JellyfinLibrary {
  JellyfinLibrary({
    required this.id,
    required this.name,
    required this.collectionType,
    this.imageTag,
  });

  final String id;
  final String name;
  final String? collectionType;
  final String? imageTag;

  factory JellyfinLibrary.fromJson(Map<String, dynamic> json) {
    return JellyfinLibrary(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      collectionType: json['CollectionType'] as String?,
      imageTag: json['ImageTags'] is Map<String, dynamic>
          ? (json['ImageTags'] as Map<String, dynamic>)['Primary'] as String?
          : null,
    );
  }

  bool get isAudioLibrary {
    final type = collectionType?.toLowerCase().trim();
    if (type == null) {
      return false;
    }
    return type == 'music' || type == 'audio';
  }

  Map<String, dynamic> toJson() {
    return {
      'Id': id,
      'Name': name,
      'CollectionType': collectionType,
      if (imageTag != null) 'ImageTags': {'Primary': imageTag},
    };
  }
}
