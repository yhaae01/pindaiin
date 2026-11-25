import 'package:path/path.dart' as p;

/// Broad category of a file tracked by the Local File Hub.
enum FileKind { pdf, image, document, spreadsheet, other }

extension FileKindX on FileKind {
  String get label => switch (this) {
    FileKind.pdf => 'PDF',
    FileKind.image => 'Image',
    FileKind.document => 'Word document',
    FileKind.spreadsheet => 'Spreadsheet',
    FileKind.other => 'File',
  };

  /// Office formats are routed through the pluggable [OfficeConverter].
  bool get isOffice => this == FileKind.document || this == FileKind.spreadsheet;
}

/// Where a record came from. Kept for future filtering/analytics.
enum FileOrigin { scan, conversion, import }

/// Quick filters shown as chips in the file hub.
enum FileHubFilter {
  all('All'),
  scans('Scans'),
  pdfs('PDFs'),
  converted('Converted');

  const FileHubFilter(this.label);

  final String label;

  bool matches(ScannedFile file) => switch (this) {
    FileHubFilter.all => true,
    FileHubFilter.scans => file.origin == FileOrigin.scan,
    FileHubFilter.pdfs => file.kind == FileKind.pdf,
    FileHubFilter.converted => file.origin == FileOrigin.conversion,
  };
}

FileKind fileKindFromPath(String path) {
  return switch (p.extension(path).toLowerCase()) {
    '.pdf' => FileKind.pdf,
    '.jpg' || '.jpeg' || '.png' || '.webp' || '.bmp' => FileKind.image,
    '.doc' || '.docx' || '.odt' || '.rtf' => FileKind.document,
    '.xls' || '.xlsx' || '.csv' => FileKind.spreadsheet,
    _ => FileKind.other,
  };
}

/// Metadata persisted in Hive. The physical bytes live in app storage and are
/// addressed by [path]; records never embed file contents.
class ScannedFile {
  const ScannedFile({
    required this.id,
    required this.name,
    required this.path,
    required this.kind,
    required this.sizeBytes,
    required this.createdAt,
    required this.origin,
    this.pageCount,
  });

  final String id;
  final String name;
  final String path;
  final FileKind kind;
  final int sizeBytes;
  final DateTime createdAt;
  final FileOrigin origin;

  /// Known for generated PDFs and for PDF -> images conversions.
  final int? pageCount;

  String get extension => p.extension(name).toLowerCase();

  ScannedFile copyWith({
    String? name,
    String? path,
    int? sizeBytes,
    int? pageCount,
    FileKind? kind,
  }) {
    return ScannedFile(
      id: id,
      name: name ?? this.name,
      path: path ?? this.path,
      kind: kind ?? this.kind,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      createdAt: createdAt,
      origin: origin,
      pageCount: pageCount ?? this.pageCount,
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    'kind': kind.name,
    'sizeBytes': sizeBytes,
    'createdAt': createdAt.millisecondsSinceEpoch,
    'origin': origin.name,
    'pageCount': pageCount,
  };

  factory ScannedFile.fromJson(Map<String, dynamic> json) {
    final kindName = json['kind'] as String?;
    final originName = json['origin'] as String?;
    return ScannedFile(
      id: json['id'] as String,
      name: json['name'] as String,
      path: json['path'] as String,
      kind: FileKind.values.firstWhere(
        (value) => value.name == kindName,
        orElse: () => FileKind.other,
      ),
      sizeBytes: (json['sizeBytes'] as num?)?.toInt() ?? 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(
        (json['createdAt'] as num?)?.toInt() ?? 0,
      ),
      origin: FileOrigin.values.firstWhere(
        (value) => value.name == originName,
        orElse: () => FileOrigin.import,
      ),
      pageCount: (json['pageCount'] as num?)?.toInt(),
    );
  }
}
