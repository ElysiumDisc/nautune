class JellyfinArtist {
  JellyfinArtist({
    required this.id,
    required this.name,
    this.primaryImageTag,
  });

  final String id;
  final String name;
  final String? primaryImageTag;

  factory JellyfinArtist.fromJson(Map<String, dynamic> json) {
    return JellyfinArtist(
      id: json['Id'] as String? ?? '',
      name: json['Name'] as String? ?? '',
      primaryImageTag:
          (json['ImageTags'] as Map<String, dynamic>?)?['Primary'] as String?,
    );
  }
}
