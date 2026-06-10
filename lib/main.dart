import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import 'android_storage_backend.dart';
import 'storage_backend.dart';
// ================= MODELS =================


class Post {
  final String id;
  String content;
  final DateTime createdAt;
  bool isPinned;


  Post({
    required this.id,
    required this.content,
    required this.createdAt,
    this.isPinned = false,
  });
}


class Note {
  final String id;
  String name;
  List<Post> posts = [];


  Note({required this.id, required this.name});
}


class SubFolder {
  String id;
  String name;
  List<Note> notes = [];


  SubFolder({required this.id, required this.name});
}


class Folder {
  String id;
  String name;
  List<SubFolder> subFolders = [];
  List<Note> notes = [];


  Folder({required this.id, required this.name});
}


// Wrapper to bundle Note with its location context
class NoteContext {
  final Note note;
  final Folder? folder;
  final SubFolder? subFolder;


  NoteContext({required this.note, this.folder, this.subFolder});
  
  bool get isRootNote => folder == null && subFolder == null;
}


// Recent Note Model for tracking history
class RecentNote {
  final String? folderName; 
  final String? subFolderName; 
  final String noteId;
  final String noteName;
  final DateTime accessedAt;


  RecentNote({
    this.folderName,
    this.subFolderName,
    required this.noteId,
    required this.noteName,
    required this.accessedAt,
  });


  String toJson() => '${folderName ?? ''}|${subFolderName ?? ''}|$noteId|$noteName|$accessedAt';


  factory RecentNote.fromJson(String json) {
    final parts = json.split('|');
    if (parts.length != 5) throw FormatException('Invalid format');
    return RecentNote(
      folderName: parts[0].isEmpty ? null : parts[0],
      subFolderName: parts[1].isEmpty ? null : parts[1],
      noteId: parts[2],
      noteName: parts[3],
      accessedAt: DateTime.parse(parts[4]),
    );
  }
}



// ================= HELPERS & REPOSITORY =================


/// Centralizes path logic using forward-slash relative paths (works across platforms).
class PathHelper {
  static String getFilePath(Note note, Folder? folder, SubFolder? subFolder) {
    if (folder == null && subFolder == null) {
      return '${note.name}.md';
    }

    final baseDir = folder!.name;
    final subDir = subFolder?.name ?? '';
    final dirPath = subDir.isEmpty ? baseDir : '$baseDir/$subDir';

    return '$dirPath/${note.name}.md';
  }


  static String getDirectoryPath(Folder? folder, SubFolder? subFolder) {
    if (folder == null && subFolder == null) {
      return '';
    }

    final baseDir = folder!.name;
    final subDir = subFolder?.name ?? '';
    return subDir.isEmpty ? baseDir : '$baseDir/$subDir';
  }
}


/// Handles all File I/O operations via a [StorageBackend].
class NoteRepository {
  final String basePath;
  final StorageBackend backend;


  NoteRepository({required this.basePath, required this.backend});


  Future<bool> checkStorageAccess() async {
    return await backend.checkAccess(basePath);
  }


  Future<void> syncFromDisk(List<Folder> folders, List<Note> rootNotes) async {
    try {
      final entries = await backend.listDirectory(basePath, '');

      folders.clear();
      rootNotes.clear();

      for (var entry in entries) {
        if (entry.isDirectory) {
          final folder = Folder(id: 'f_${entry.name}', name: entry.name);

          final subEntries = await backend.listDirectory(basePath, entry.name);
          for (var sfEntity in subEntries) {
            if (sfEntity.isDirectory) {
              final subFolder = SubFolder(id: 'sf_${folder.name}_${sfEntity.name}', name: sfEntity.name);

              final noteEntries = await backend.listDirectory(basePath, '${entry.name}/${sfEntity.name}');
              for (var noteEntity in noteEntries) {
                if (!noteEntity.isDirectory && noteEntity.name.endsWith('.md')) {
                  final noteName = noteEntity.name.replaceAll('.md', '');
                  final note = Note(id: 'n_${noteName.hashCode}_${sfEntity.name.hashCode}', name: noteName);
                  await loadNote(note, subFolder, folder);
                  subFolder.notes.add(note);
                }
              }
              folder.subFolders.add(subFolder);
            } else if (sfEntity.name.endsWith('.md')) {
              final noteName = sfEntity.name.replaceAll('.md', '');
              final note = Note(id: 'n_${noteName.hashCode}_${folder.name.hashCode}', name: noteName);
              await loadNote(note, null, folder);
              folder.notes.add(note);
            }
          }
          folders.add(folder);
        }
        else if (!entry.isDirectory && entry.name.endsWith('.md')) {
          final noteName = entry.name.replaceAll('.md', '');
          // Avoid loading hidden files or system files if any
          if (!noteName.startsWith('.')) {
            final note = Note(id: 'n_root_${noteName.hashCode}', name: noteName);
            await loadNote(note, null, null);
            rootNotes.add(note);
          }
        }
      }
    } catch (e) {
      debugPrint('Sync failed: $e');
      rethrow;
    }
  }


  Future<void> saveNote(Note note, SubFolder? subFolder, Folder? folder) async {
    try {
      final relPath = PathHelper.getFilePath(note, folder, subFolder);

      String mdContent = '';

      for (var post in note.posts) {
        if (post.isPinned) mdContent += '<!-- PINNED -->\n';
        mdContent += '${post.content}\n---\n\n';
      }

      await backend.writeFile(basePath, relPath, mdContent);
    } catch (e) {
      debugPrint('Save failed: $e');
      rethrow;
    }
  }


  Future<void> loadNote(Note note, SubFolder? subFolder, Folder? folder) async {
    try {
      final relPath = PathHelper.getFilePath(note, folder, subFolder);
      String content = await backend.readFile(basePath, relPath);
      final sections = content.split(RegExp(r'^\s*---\s*$', multiLine: true));


      note.posts.clear();
      for (var i = 0; i < sections.length; i++) {
        var section = sections[i].trim();
        if (section.isEmpty) continue;


        bool pinned = section.startsWith('<!-- PINNED -->');
        String cleanContent = pinned
            ? section.replaceFirst(RegExp(r'^<!--\s*PINNED\s*-->\s*\n?', multiLine: true), '').trim()
            : section;


        note.posts.add(Post(
          id: '${DateTime.now().microsecondsSinceEpoch}_${i}',
          content: cleanContent,
          createdAt: DateTime.now(),
          isPinned: pinned,
        ));
      }
    } catch (e) {
      debugPrint('Load error: $e');
      rethrow;
    }
  }


  Future<void> deleteNoteFile(Note note, SubFolder? subFolder, Folder? folder) async {
    try {
      final relPath = PathHelper.getFilePath(note, folder, subFolder);
      await backend.deleteEntry(basePath, relPath);
    } catch (e) {
      debugPrint('Delete file failed: $e');
      rethrow;
    }
  }


  Future<void> renameNoteFile(Note note, String newName, SubFolder? subFolder, Folder? folder) async {
    try {
      final oldRelPath = PathHelper.getFilePath(note, folder, subFolder);

      // Build new relative path
      final tempNote = Note(id: note.id, name: newName);
      final newFileName = '${tempNote.name}.md';

      await backend.renameEntry(basePath, oldRelPath, newFileName);
    } catch (e) {
      debugPrint('Rename file failed: $e');
      rethrow;
    }
  }


  Future<void> deleteFolderDirectory(String folderName) async {
    try {
      await backend.deleteEntry(basePath, folderName);
    } catch (e) {
      debugPrint('Delete folder failed: $e');
      rethrow;
    }
  }


  Future<void> renameFolderDirectory(String oldName, String newName) async {
    try {
      await backend.renameEntry(basePath, oldName, newName);
    } catch (e) {
      debugPrint('Rename folder failed: $e');
      rethrow;
    }
  }


  Future<void> deleteSubFolderDirectory(String folderName, String subFolderName) async {
    try {
      await backend.deleteEntry(basePath, '$folderName/$subFolderName');
    } catch (e) {
      debugPrint('Delete subfolder failed: $e');
      rethrow;
    }
  }


  Future<void> renameSubFolderDirectory(String folderName, String oldSfName, String newSfName) async {
    try {
      await backend.renameEntry(basePath, '$folderName/$oldSfName', newSfName);
    } catch (e) {
      debugPrint('Rename subfolder failed: $e');
      rethrow;
    }
  }

  /// Ensure a directory exists for the given folder/subFolder context.
  Future<void> ensureDirectory(Folder? folder, SubFolder? subFolder) async {
    final dirPath = PathHelper.getDirectoryPath(folder, subFolder);
    if (dirPath.isNotEmpty) {
      await backend.createDirectory(basePath, dirPath);
    }
  }
}



// ================= STATE MANAGEMENT =================


class AppData extends ChangeNotifier {
  List<Folder> folders = [];
  List<Note> rootNotes = [];

  String savePath = '';
  String appName = 'darkslip';
  Set<String> expandedTiles = {};

  bool _initialized = false;
  bool _storageReady = false;
  bool _onboardingCompleted = false;

  // Added to fix the undefined getter error
  String? _lastError;

  // Recent Notes Tracking
  List<RecentNote> recentNotes = [];


  late NoteRepository repository;
  late StorageBackend storageBackend;


  bool get storageReady => _storageReady;
  bool get onboardingCompleted => _onboardingCompleted;


  /// Returns true if running on Android.
  bool get isAndroid => Platform.isAndroid;

  /// Returns true if running on a desktop platform (Windows, macOS, Linux).
  bool get isDesktop => Platform.isWindows || Platform.isMacOS || Platform.isLinux;


  Future<void> init() async {
    if (_initialized) return;

    // Create the correct backend for this platform
    storageBackend = _createStorageBackend();

    final prefs = await SharedPreferences.getInstance();
    appName = prefs.getString('app_name') ?? 'darkslip';
    savePath = prefs.getString('save_path') ?? '';

    expandedTiles.addAll(prefs.getStringList('expanded_tiles') ?? []);
    _onboardingCompleted = prefs.getBool('onboarding_completed') ?? false;


    // On Android, resolve the real SAF tree URI from Kotlin's persisted storage.
    // The old savePath may be a stale raw filesystem path — replace it with the
    // actual content:// URI that Kotlin has stored via takePersistableUriPermission.
    if (isAndroid) {
      final androidBackend = storageBackend as AndroidStorageBackend;
      final treeUri = await androidBackend.getSavedTreeUri();
      if (treeUri != null && treeUri.isNotEmpty) {
        savePath = treeUri;
        // Update SharedPreferences so future restarts also have the correct URI
        await prefs.setString('save_path', treeUri);
        debugPrint('[AppData] Resolved SAF tree URI: $treeUri');
      } else if (savePath.isNotEmpty && !savePath.startsWith('content://')) {
        // Old raw path with no persisted SAF URI — storage won't work, clear it
        debugPrint('[AppData] Old save_path is not a content URI and no tree_uri found — clearing');
        await prefs.remove('save_path');
        savePath = '';
      }
    }

    repository = NoteRepository(basePath: savePath, backend: storageBackend);

    // If we have a saved path, try to use it
    if (savePath.isNotEmpty) {
      _storageReady = await repository.checkStorageAccess();
      if (_storageReady) {
        try {
          await repository.syncFromDisk(folders, rootNotes);
        } catch (e) {
          debugPrint("Init sync error: $e");
          _lastError = e.toString();
        }
      } else {
        _lastError = "Storage access denied or unavailable.";
      }
    }
    // If no saved path, wait for onboarding to pick a folder

    await _loadRecentNotes();
    _initialized = true;
    notifyListeners();
  }


  /// Create the appropriate StorageBackend for the current platform.
  StorageBackend _createStorageBackend() {
    if (isAndroid) {
      return AndroidStorageBackend();
    } else {
      return DesktopStorageBackend();
    }
  }


  Future<void> completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_completed', true);
    _onboardingCompleted = true;
    notifyListeners();
  }


  /// Pick a folder using the platform-native picker, then initialize storage.
  Future<void> pickAndInitializeFolder() async {
    String? selectedPath;

    if (isAndroid) {
      // SAF: launch folder picker via method channel
      selectedPath = await storageBackend.pickDirectory();
    } else if (isDesktop) {
      // Desktop: default to the app's documents directory + "darkslip"
      final docsDir = await getApplicationDocumentsDirectory();
      selectedPath = '${docsDir.path}\\darkslip';
    }

    if (selectedPath != null && selectedPath.isNotEmpty) {
      debugPrint('[AppData] Initializing storage at: $selectedPath');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('save_path', selectedPath);
      savePath = selectedPath;

      repository = NoteRepository(basePath: savePath, backend: storageBackend);
      _storageReady = await repository.checkStorageAccess();
      debugPrint('[AppData] Storage ready: $_storageReady');

      if (_storageReady) {
        try {
          await repository.syncFromDisk(folders, rootNotes);
          _lastError = null;
          debugPrint('[AppData] Sync OK — ${folders.length} folders, ${rootNotes.length} notes');
        } catch (e) {
          debugPrint("Folder init sync error: $e");
          _lastError = e.toString();
        }
      } else {
        _lastError = "Could not access selected folder.";
      }
    }

    notifyListeners();
  }


  Future<void> retryStorageInit() async {
    debugPrint('[AppData] Retry storage init at: $savePath');
    repository = NoteRepository(basePath: savePath, backend: storageBackend);
    _storageReady = await repository.checkStorageAccess();
    debugPrint('[AppData] Storage ready after retry: $_storageReady');
    if (_storageReady) {
      try {
        await repository.syncFromDisk(folders, rootNotes);
        _lastError = null;
      } catch (e) {
        debugPrint("Retry sync error: $e");
        _lastError = e.toString();
      }
    } else {
       _lastError = "Storage access denied or unavailable.";
    }
    notifyListeners();
  }


  /// On Android this is an alias for [pickAndInitializeFolder] (SAF).
  /// On desktop platforms there are no permissions to request.
  Future<void> requestStoragePermission() async {
    if (isAndroid) {
      await pickAndInitializeFolder();
    } else {
      // Desktop: just re-check access at current path
      await retryStorageInit();
    }
  }


  void updateSavePath(String newPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('save_path', newPath);
    savePath = newPath;

    repository = NoteRepository(basePath: savePath, backend: storageBackend);
    try {
      await repository.syncFromDisk(folders, rootNotes);
    } catch (e) {
      debugPrint("Update path sync error: $e");
    }
    notifyListeners();
  }


  void setAppName(String name) async {
    final trimmed = name.trim();
    if (trimmed.length <= 32 && trimmed.isNotEmpty) {
      appName = trimmed;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_name', appName);
      notifyListeners();
    }
  }


  // Persistence Helpers
  
  Future<void> _saveExpandedTiles() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('expanded_tiles', expandedTiles.toList());
  }


  void toggleExpanded(String id) {
    if (expandedTiles.contains(id)) {
      expandedTiles.remove(id);
    } else {
      expandedTiles.add(id);
    }
    _saveExpandedTiles();
    notifyListeners();
  }


  Future<void> _saveRecentNotes() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('recent_notes', recentNotes.map((r) => r.toJson()).toList());
  }


  Future<void> _loadRecentNotes() async {
    final prefs = await SharedPreferences.getInstance();
    final list = prefs.getStringList('recent_notes') ?? [];
    recentNotes = list.map((s) => RecentNote.fromJson(s)).toList();
  }



  // --- SEARCH & CONTEXT HELPERS ---


  /// Finds a NoteContext (Note + Parent Folder/SubFolder) by ID across the entire hierarchy.
  NoteContext? findNoteById(String noteId) {
    // Check root notes first
    for (var n in rootNotes) {
      if (n.id == noteId) return NoteContext(note: n);
    }


    // Check folders and subfolders
    for (var f in folders) {
      // Check folder-level notes
      for (var n in f.notes) {
        if (n.id == noteId) return NoteContext(note: n, folder: f);
      }
      
      // Check subfolder notes
      for (var sf in f.subFolders) {
        for (var n in sf.notes) {
          if (n.id == noteId) return NoteContext(note: n, folder: f, subFolder: sf);
        }
      }
    }
    return null;
  }


  /// Adds a note to recent history. Handles finding the context automatically.
  Future<void> addRecentNote(String? folderName, String? subFolderName, String noteId, String noteName) async {
    // Remove existing entry if present
    recentNotes.removeWhere((r) => r.noteId == noteId);
    
    recentNotes.insert(0, RecentNote(
      folderName: folderName,
      subFolderName: subFolderName,
      noteId: noteId,
      noteName: noteName,
      accessedAt: DateTime.now(),
    ));
    
    if (recentNotes.length > 9) recentNotes.removeLast();


    await _saveRecentNotes();
    notifyListeners();
  }



  // --- CRUD OPERATIONS ---


  Future<void> createFolder(String name) async {
    folders.add(Folder(id: 'f_$name', name: name));
    notifyListeners();
  }


  Future<void> renameFolder(Folder folder, String newName) async {
    try {
      await repository.renameFolderDirectory(folder.name, newName);
      
      expandedTiles.remove(folder.id);
      folder.id = 'f_$newName';
      folder.name = newName;
    } catch (e) { 
      debugPrint('Rename failed: $e'); 
    }
    notifyListeners();
  }


  Future<void> deleteFolder(Folder folder) async {
    try {
      await repository.deleteFolderDirectory(folder.name);
      
      folders.removeWhere((f) => f.id == folder.id);
      expandedTiles.remove(folder.id);
    } catch (e) { 
      debugPrint('Delete failed: $e'); 
    }
    notifyListeners();
  }


  Future<void> createSubFolder(String name, Folder folder) async {
    final sfId = 'sf_${folder.name}_$name';
    folder.subFolders.add(SubFolder(id: sfId, name: name));
    expandedTiles.add(folder.id);
    notifyListeners();
  }


  Future<void> renameSubFolder(SubFolder subFolder, Folder parentFolder, String newName) async {
    try {
      await repository.renameSubFolderDirectory(parentFolder.name, subFolder.name, newName);
      
      expandedTiles.remove(subFolder.id);
      subFolder.id = 'sf_${parentFolder.name}_$newName';
      subFolder.name = newName;
    } catch (e) { 
      debugPrint('Rename failed: $e'); 
    }
    notifyListeners();
  }


  Future<void> deleteSubFolder(SubFolder subFolder, Folder parentFolder) async {
    try {
      await repository.deleteSubFolderDirectory(parentFolder.name, subFolder.name);
      
      parentFolder.subFolders.removeWhere((sf) => sf.id == subFolder.id);
      expandedTiles.remove(subFolder.id);
    } catch (e) { 
      debugPrint('Delete failed: $e'); 
    }
    notifyListeners();
  }


  Future<void> createNote(String name, Folder folder, {SubFolder? subFolder}) async {
    final newNote = Note(id: 'n_${name.hashCode}_${(subFolder?.name ?? folder.name).hashCode}', name: name);
    if (subFolder != null) {
      subFolder.notes.add(newNote);
      expandedTiles.add(subFolder.id);
    } else {
      folder.notes.add(newNote);
      expandedTiles.add(folder.id);
    }
    try {
      await repository.saveNote(newNote, subFolder, folder);
    } catch (e) {
     debugPrint("Create note save failed: $e");
    }
    notifyListeners();
  }


  Future<void> createRootNote(String name) async {
    final newNote = Note(id: 'n_root_${name.hashCode}', name: name);
    rootNotes.add(newNote);
    try {
      await repository.saveNote(newNote, null, null);
    } catch (e) {
     debugPrint("Create root note save failed: $e");
    }
    notifyListeners();
  }


  Future<void> renameNote(NoteContext context, String newName) async {
    try {
      await repository.renameNoteFile(context.note, newName, context.subFolder, context.folder);
      context.note.name = newName;
    } catch (e) { 
      debugPrint('Rename failed: $e'); 
    }
    notifyListeners();
  }


  Future<void> deleteNote(NoteContext context) async {
    try {
      await repository.deleteNoteFile(context.note, context.subFolder, context.folder);
      
      if (context.isRootNote) {
        rootNotes.removeWhere((n) => n.id == context.note.id);
      } else if (context.subFolder != null) {
        context.subFolder!.notes.removeWhere((n) => n.id == context.note.id);
      } else {
        context.folder!.notes.removeWhere((n) => n.id == context.note.id);
      }
    } catch (e) { 
      debugPrint('Delete failed: $e'); 
    }
    notifyListeners();
  }


  Future<void> togglePin(NoteContext context, Post post) async {
    post.isPinned = !post.isPinned;
    try {
      await repository.saveNote(context.note, context.subFolder, context.folder);
    } catch (e) {
     debugPrint("Toggle pin save failed: $e");
    }
  }


  void updatePostContent(Post post, String newContent) {
    post.content = newContent;
    notifyListeners();
  }


  /// Unified method to paste clipboard content into a specific note.
  Future<bool> pasteClipboardToNote(String targetNoteId) async {
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    final text = clipboardData?.text;


    if (text == null || text.isEmpty) return false;


    final context = findNoteById(targetNoteId);
    
    if (context != null) {
      final newPost = Post(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        content: text,
        createdAt: DateTime.now(),
      );
      context.note.posts.insert(0, newPost);
      
      try {
        await repository.saveNote(context.note, context.subFolder, context.folder);
        notifyListeners(); // Update UI to show new post if visible
        return true;
      } catch (e) {
        debugPrint("Paste save failed: $e");
        return false;
      }
    } 
    return false; // Note not found
  }
}



// ================= THEME =================


ThemeData darkSlipTheme() => ThemeData(
  brightness: Brightness.dark,
  primaryColor: const Color(0xFF2A2A2A),
  scaffoldBackgroundColor: const Color(0xFF181818),
  cardColor: const Color(0xFF252525),
  dividerColor: const Color(0xFF333333),
  textTheme: const TextTheme(
    bodyLarge: TextStyle(color: Color(0xFFE0E0E0)),
    titleMedium: TextStyle(color: Color(0xFFFFFFFF), fontWeight: FontWeight.w600),
  ),
  appBarTheme: const AppBarTheme(
    backgroundColor: Color(0xFF2A2A2A),
    elevation: 0,
    iconTheme: IconThemeData(color: Colors.white70),
  ),
  inputDecorationTheme: InputDecorationTheme(
    filled: true,
    fillColor: const Color(0xFF333333),
    border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
    contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
  ),
);



// ================= SCREENS =================


/// Shared Recent Notes dialog — usable from any screen.
void showRecentNotesDialog(BuildContext context) {
  bool pasteToEnabled = false;

  showDialog(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setDialogState) => AlertDialog(
        backgroundColor: Colors.grey[900],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Recent Notes', style: TextStyle(color: Colors.white)),
        content: Consumer<AppData>(
          builder: (ctx, data, _) {
            final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
            
            final gridContent = GridView.count(
              shrinkWrap: true,
              crossAxisCount: 3,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              children: List.generate(9, (index) {
                if (index < data.recentNotes.length) {
                  final recent = data.recentNotes[index];
                  return _buildRecentTile(recent, ctx, pasteToEnabled);
                } else {
                  return Container(
                    decoration: BoxDecoration(
                      color: Colors.grey[850],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey[700]!),
                    ),
                    child: const Center(child: Text('Empty', style: TextStyle(color: Colors.grey, fontSize: 12))),
                  );
                }
              }),
            );

            final footer = Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0, horizontal: 4.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Checkbox(
                        value: pasteToEnabled,
                        activeColor: Colors.white70,
                        checkColor: Colors.grey[900],
                        onChanged: (val) {
                          pasteToEnabled = val ?? false;
                          setDialogState(() {});
                        },
                      ),
                      const Text('Paste To', style: TextStyle(color: Colors.white70)),
                    ],
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Close'),
                  ),
                ],
              ),
            );

            final innerContent = Column(
              mainAxisSize: MainAxisSize.min,
              children: [gridContent, footer],
            );

            if (isDesktop) {
              // On desktop AlertDialog gives infinite height to content.
              // Let the shrinkWrap GridView size itself naturally (~250px),
              // only scroll if the window is genuinely too small.
              final availableH = MediaQuery.of(ctx).size.height;
              // Subtract overhead: window title bar, dialog title/padding, safe margins
              final maxContentH = availableH * 0.75;
              
              return SizedBox(
                width: 520,
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxContentH),
                  child: SingleChildScrollView(
                    child: innerContent,
                  ),
                ),
              );
            }

            return SizedBox(
              width: double.maxFinite,
              child: innerContent,
            );
          },
        ),
      ),
    ),
  );
}


Widget _buildRecentTile(RecentNote recent, BuildContext ctx, bool pasteToEnabled) {
  return GestureDetector(
    onTap: () async {
      final data = ctx.read<AppData>();

      // Use the centralized search helper
      final noteCtx = data.findNoteById(recent.noteId);


      if (noteCtx != null) {
        Navigator.pop(ctx);

        // Update recent history with current location info
        data.addRecentNote(
          noteCtx.folder?.name,
          noteCtx.subFolder?.name,
          noteCtx.note.id,
          noteCtx.note.name
        );


        // If paste to is enabled, use the centralized paste method
        if (pasteToEnabled) {
         final success = await data.pasteClipboardToNote(noteCtx.note.id);
         if (!success && ctx.mounted) {
           ScaffoldMessenger.of(ctx).showSnackBar(
             const SnackBar(content: Text('Failed to paste. Clipboard empty or note not found.')),
           );
         }
        }


        if (ctx.mounted) {
          Navigator.push(ctx, MaterialPageRoute(builder: (_) => NoteScreen(context: noteCtx)));
        }
      } else {
       // Note might have been deleted from disk but still in recent history
       if (ctx.mounted) {
         ScaffoldMessenger.of(ctx).showSnackBar(
           const SnackBar(content: Text('Note not found or deleted.')),
         );
       }
      }
    },
    child: Container(
      decoration: BoxDecoration(
        color: Colors.grey[800],
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey[700]!),
      ),
      child: Center(
        child: Text(recent.noteName, style: const TextStyle(color: Colors.white70, fontSize: 13), textAlign: TextAlign.center),
      ),
    ),
  );
}


class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});


  void _showInputDialog(BuildContext ctx, String title, TextEditingController controller, Function(String) onConfirm) {
    showDialog(
      context: ctx,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: Text(title, style: const TextStyle(color: Colors.white)),
        content: TextField(controller: controller, decoration: InputDecoration(hintText: 'Enter name')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          TextButton(
            onPressed: () { 
              if (controller.text.trim().isNotEmpty) {
                onConfirm(controller.text.trim());
                Navigator.pop(ctx);
              }
            }, 
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }


  void _showItemMenu(BuildContext ctx, String title, {required Function() onRename, required Function() onDelete}) {
    showMenu(
      context: ctx,
      position: RelativeRect.fromLTRB(100, 200, 100, 200),
      items: [
        PopupMenuItem(value: 'rename', child: Text('Rename $title')),
        PopupMenuItem(value: 'delete', child: Text('Delete $title'), enabled: true),
      ],
    ).then((val) {
      if (val == 'rename') onRename();
      else if (val == 'delete') onDelete();
    });
  }


  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Consumer<AppData>(
          builder: (ctx, data, _) {
            final renameHandler = () {
              final ctrl = TextEditingController(text: data.appName);
              showDialog(
                context: ctx,
                builder: (_) => AlertDialog(
                  backgroundColor: Colors.grey[900],
                  title: const Text('Rename App Title', style: TextStyle(color: Colors.white)),
                  content: TextField(controller: ctrl, maxLength: 32, decoration: const InputDecoration(hintText: 'Max 32 characters')),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
                    TextButton(
                      onPressed: () {
                        if (ctrl.text.trim().isNotEmpty && ctrl.text.length <= 32) {
                          data.setAppName(ctrl.text);
                          Navigator.pop(ctx);
                        }
                      },
                      child: const Text('Save'),
                    ),
                  ],
                ),
              );
            };
            return GestureDetector(
              onLongPress: renameHandler,
              onSecondaryTap: (Platform.isWindows || Platform.isMacOS || Platform.isLinux) ? renameHandler : null,
              child: Text(data.appName),
            );
          },
        ),
        actions: [
            IconButton(
                icon: const Icon(Icons.grid_view),
                onPressed: () => showRecentNotesDialog(context),
                tooltip: 'Recent Notes',
            ),
            // Copy to Last Note Button
            Consumer<AppData>(
              builder: (ctx, data, _) {
                final hasRecentNote = data.recentNotes.isNotEmpty;
                return IconButton(
                  icon: const Icon(Icons.content_paste_go),
                  color: hasRecentNote ? Colors.white70 : Colors.grey[600],
                  onPressed: !hasRecentNote 
                    ? null 
                    : () async {
                        final lastNote = data.recentNotes.first;
                        final success = await data.pasteClipboardToNote(lastNote.noteId);
                        
                        if (ctx.mounted) {
                          if (success) {
                            ScaffoldMessenger.of(ctx).showSnackBar(
                              SnackBar(content: Text('Pasted to ${lastNote.noteName}'), duration: Duration(seconds: 1)),
                            );
                          } else {
                           ScaffoldMessenger.of(ctx).showSnackBar(
                             const SnackBar(content: Text('Failed to paste. Clipboard empty or note not found.'), duration: Duration(seconds: 2)),
                           );
                          }
                        }
                      },
                  tooltip: 'Copy to Last Note',
                );
              },
            ),
            // Add Root Note Button
            IconButton(
                icon: const Icon(Icons.note_add),
                onPressed: () {
                    final ctrl = TextEditingController();
                    _showInputDialog(context, 'New Root Note', ctrl, (name) => context.read<AppData>().createRootNote(name));
                },
                tooltip: 'New Root Note',
            ),
            IconButton(
                icon: const Icon(Icons.create_new_folder),
                onPressed: () {
                    final ctrl = TextEditingController();
                    _showInputDialog(context, 'New Folder', ctrl, (name) => context.read<AppData>().createFolder(name));
                },
                tooltip: 'New Folder',
            ),
            IconButton(
                icon: const Icon(Icons.settings), 
                onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen())),
            ),
        ],
      ),
      body: Consumer<AppData>(
        builder: (ctx, data, _) {
          if (!data.storageReady) {
           return Center(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.drive_folder_upload_rounded,
                    size: 80,
                    color: Colors.grey[600],
                  ),
                  const SizedBox(height: 24),
                  Text(
                    'Storage Error',
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.red[300]),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    data._lastError ?? "Initializing...",
                    textAlign: TextAlign.center,
                    style: const TextStyle(color: Colors.grey),
                  ),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        await data.pickAndInitializeFolder();
                      },
                      icon: const Icon(Icons.folder_open),
                      label: const Text('Select a Folder', style: TextStyle(fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black87,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await data.retryStorageInit();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Check Again', style: TextStyle(fontSize: 16)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        side: BorderSide(color: Colors.grey[700]!),
                        foregroundColor: Colors.white70,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          );
          }

          // Display Root Notes first, then Folders
          final allItems = [
            ...data.rootNotes.map((note) => _buildNoteTile(ctx, data, NoteContext(note: note))),
            ...data.folders.map((folder) => _buildFolderTile(ctx, data, folder)),
          ];


          return ListView.builder(
            itemCount: allItems.length,
            itemBuilder: (_, i) => allItems[i],
          );
        },
      ),
    );
  }


  Widget _buildFolderTile(BuildContext ctx, AppData data, Folder folder) {
    final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    return GestureDetector(
      onLongPress: () => _showItemMenu(ctx, 'Folder', 
        onRename: () => _showInputDialog(ctx, 'Rename Folder', TextEditingController(text: folder.name), (name) => data.renameFolder(folder, name)),
        onDelete: () {
          showDialog(context: ctx, builder: (_) => AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text('Delete Folder?', style: TextStyle(color: Colors.white)),
            content: Text('This will permanently delete "${folder.name}" and all its contents.', style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(
                onPressed: () { 
                  data.deleteFolder(folder); 
                  Navigator.pop(ctx); 
                }, 
                style: ButtonStyle(foregroundColor: WidgetStateProperty.all(Colors.red)), 
                child: const Text('Delete')
              ),
            ],
          ));
        }
      ),
      onSecondaryTap: isDesktop ? () => _showItemMenu(ctx, 'Folder', 
        onRename: () => _showInputDialog(ctx, 'Rename Folder', TextEditingController(text: folder.name), (name) => data.renameFolder(folder, name)),
        onDelete: () {
          showDialog(context: ctx, builder: (_) => AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text('Delete Folder?', style: TextStyle(color: Colors.white)),
            content: Text('This will permanently delete "${folder.name}" and all its contents.', style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(
                onPressed: () { 
                  data.deleteFolder(folder); 
                  Navigator.pop(ctx); 
                }, 
                style: ButtonStyle(foregroundColor: WidgetStateProperty.all(Colors.red)), 
                child: const Text('Delete')
              ),
            ],
          ));
        }
      ) : null,
      child: ExpansionTile(
        initiallyExpanded: data.expandedTiles.contains(folder.id),
        onExpansionChanged: (expanded) => data.toggleExpanded(folder.id),
        leading: const Icon(Icons.folder, color: Colors.white70),
        title: Text(folder.name),
        trailing: PopupMenuButton<String>(
          icon: const Icon(Icons.add_circle_outline),
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'subfolder', child: Text('New SubFolder')),
            const PopupMenuItem(value: 'note', child: Text('New Note')),
          ],
          onSelected: (value) {
            if (value == 'subfolder') {
              _showInputDialog(ctx, 'New SubFolder', TextEditingController(), (name) => data.createSubFolder(name, folder));
            } else if (value == 'note') {
              _showInputDialog(ctx, 'New Note', TextEditingController(), (name) => data.createNote(name, folder));
            }
          },
        ),
        children: [
          ...folder.notes.map((note) => _buildNoteTile(ctx, data, NoteContext(note: note, folder: folder))),
          if (folder.subFolders.isEmpty && folder.notes.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('No subfolders or notes yet.', style: TextStyle(color: Colors.grey))),
          ...folder.subFolders.map((sf) => _buildSubFolderTile(ctx, data, folder, sf)),
        ],
      ),
    );
  }


  Widget _buildSubFolderTile(BuildContext ctx, AppData data, Folder parentFolder, SubFolder subFolder) {
    final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    return GestureDetector(
      onLongPress: () => _showItemMenu(ctx, 'SubFolder',
        onRename: () => _showInputDialog(ctx, 'Rename SubFolder', TextEditingController(text: subFolder.name), (name) => data.renameSubFolder(subFolder, parentFolder, name)),
        onDelete: () {
          showDialog(context: ctx, builder: (_) => AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text('Delete SubFolder?', style: TextStyle(color: Colors.white)),
            content: Text('This will permanently delete "${subFolder.name}" and its notes.', style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(
                onPressed: () { 
                  data.deleteSubFolder(subFolder, parentFolder); 
                  Navigator.pop(ctx); 
                }, 
                style: ButtonStyle(foregroundColor: WidgetStateProperty.all(Colors.red)), 
                child: const Text('Delete')
              ),
            ],
          ));
        }
      ),
      onSecondaryTap: isDesktop ? () => _showItemMenu(ctx, 'SubFolder',
        onRename: () => _showInputDialog(ctx, 'Rename SubFolder', TextEditingController(text: subFolder.name), (name) => data.renameSubFolder(subFolder, parentFolder, name)),
        onDelete: () {
          showDialog(context: ctx, builder: (_) => AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text('Delete SubFolder?', style: TextStyle(color: Colors.white)),
            content: Text('This will permanently delete "${subFolder.name}" and its notes.', style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(
                onPressed: () { 
                  data.deleteSubFolder(subFolder, parentFolder); 
                  Navigator.pop(ctx); 
                }, 
                style: ButtonStyle(foregroundColor: WidgetStateProperty.all(Colors.red)), 
                child: const Text('Delete')
              ),
            ],
          ));
        }
      ) : null,
      child: ExpansionTile(
        initiallyExpanded: data.expandedTiles.contains(subFolder.id),
        onExpansionChanged: (expanded) => data.toggleExpanded(subFolder.id),
        leading: const Icon(Icons.folder_open, color: Colors.white70),
        title: Text(subFolder.name),
                trailing: IconButton(
          icon: const Icon(Icons.add_circle_outline), 
          onPressed: () => _showInputDialog(ctx, 'New Note', TextEditingController(), (name) => data.createNote(name, parentFolder, subFolder: subFolder))
        ),
        children: [
          if (subFolder.notes.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('No notes yet.', style: TextStyle(color: Colors.grey))),
          ...subFolder.notes.map((note) => _buildNoteTile(ctx, data, NoteContext(note: note, folder: parentFolder, subFolder: subFolder))),
        ],
      ),
    );
  }


  Widget _buildNoteTile(BuildContext ctx, AppData data, NoteContext context) {
    final isDesktop = Platform.isWindows || Platform.isMacOS || Platform.isLinux;
    return GestureDetector(
      onLongPress: () => _showItemMenu(ctx, 'Note',
        onRename: () => _showInputDialog(ctx, 'Rename Note', TextEditingController(text: context.note.name), (name) => data.renameNote(context, name)),
        onDelete: () {
          showDialog(context: ctx, builder: (_) => AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text('Delete Note?', style: TextStyle(color: Colors.white)),
            content: Text('This will permanently delete "${context.note.name}" and its file.', style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(
                onPressed: () { 
                  data.deleteNote(context); 
                  Navigator.pop(ctx); 
                }, 
                style: ButtonStyle(foregroundColor: WidgetStateProperty.all(Colors.red)), 
                child: const Text('Delete')
              ),
            ],
          ));
        }
      ),
      onSecondaryTap: isDesktop ? () => _showItemMenu(ctx, 'Note',
        onRename: () => _showInputDialog(ctx, 'Rename Note', TextEditingController(text: context.note.name), (name) => data.renameNote(context, name)),
        onDelete: () {
          showDialog(context: ctx, builder: (_) => AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text('Delete Note?', style: TextStyle(color: Colors.white)),
            content: Text('This will permanently delete "${context.note.name}" and its file.', style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(
                onPressed: () { 
                  data.deleteNote(context); 
                  Navigator.pop(ctx); 
                }, 
                style: ButtonStyle(foregroundColor: WidgetStateProperty.all(Colors.red)), 
                child: const Text('Delete')
              ),
            ],
          ));
        }
      ) : null,
      child: ListTile(
        leading: Icon(context.isRootNote ? Icons.note : Icons.note_outlined, color: Colors.white70),
        title: Text(context.note.name),
        subtitle: Text('${context.note.posts.length} posts'),
        onTap: () {
          data.addRecentNote(context.folder?.name, context.subFolder?.name, context.note.id, context.note.name);
          Navigator.push(ctx, MaterialPageRoute(builder: (_) => NoteScreen(context: context)));
        },
      ),
    );
  }
}


class NoteScreen extends StatefulWidget {
  final NoteContext context;
  
  const NoteScreen({super.key, required this.context});


  @override
  State<NoteScreen> createState() => _NoteScreenState();
}


class _NoteScreenState extends State<NoteScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final FocusNode _editorFocusNode = FocusNode();
  final FocusNode _keyboardFocusNode = FocusNode();
  String? _highlightedPostId;
  Timer? _highlightTimer;
  Post? _editingPost; 


  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadNote());
  }


  Future<void> _loadNote() async {
    // Reload note content from disk to ensure we have the latest data
    await context.read<AppData>().repository.loadNote(widget.context.note, widget.context.subFolder, widget.context.folder);
    if (mounted) {
      setState(() {}); 
      
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scrollController.hasClients) {
          _scrollController.jumpTo(0);
        }
      });
    }
  }


  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Copied to clipboard!'), duration: Duration(seconds: 1)),
      );
    }
  }


  String _prepareMarkdownContent(String content) {
    final lines = content.split('\n');
    final result = <String>[];
    bool inTable = false;


    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      final isTableLine = RegExp(r'^\s*\|.*\|\s*$').hasMatch(line);
      final isSeparatorLine = RegExp(r'^\s*\|[\s\-:|]+\|$').hasMatch(line);


      if (isTableLine || isSeparatorLine) {
        inTable = true;
        result.add(line);
      } else if (inTable && line.trim().isEmpty) {
        inTable = false;
        result.add(''); 
      } else if (inTable) {
        inTable = false;
        result.add('');
        result.add(line);
      } else {
        if (line.isNotEmpty) {
          result.add(line);
          result.add('');
        } else {
          result.add('');
        }
      }
    }


    return result.join('\n');
  }


  void _insertCodeBlock() {
    final currentText = _controller.text;
    final selection = _controller.selection;
    const codeBlockSyntax = '```\n\n```';
    final insertPos = selection.isValid ? selection.start : currentText.length;


    String newText;
    int newCursorPos;


    if (selection.isCollapsed) {
      newText = currentText.replaceRange(insertPos, insertPos, codeBlockSyntax);
      newCursorPos = insertPos + 4;
    } else {
      final selectedText = currentText.substring(selection.start, selection.end);
      newText = currentText.replaceRange(selection.start, selection.end, '```\n$selectedText\n```');
      newCursorPos = selection.start + 4;
    }


    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorPos),
    );
    FocusScope.of(context).requestFocus(FocusNode());
  }


  void _insertQuoteBlock() {
    final currentText = _controller.text;
    final selection = _controller.selection;
    final insertPos = selection.isValid ? selection.start : currentText.length;


    String newText;
    int newCursorPos;


    if (selection.isCollapsed) {
      const quoteSyntax = '> ';
      newText = currentText.replaceRange(insertPos, insertPos, quoteSyntax);
      newCursorPos = insertPos + 2;
    } else {
      final selectedText = currentText.substring(selection.start, selection.end);
      final quotedLines = selectedText.split('\n').map((line) => '> $line').join('\n');
      newText = currentText.replaceRange(selection.start, selection.end, quotedLines);
      newCursorPos = selection.start + 2;
    }


    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorPos),
    );
    FocusScope.of(context).requestFocus(FocusNode());
  }


  void _saveOrAddPost() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;


    if (_editingPost != null) {
      context.read<AppData>().updatePostContent(_editingPost!, text);
      // Save immediately on edit save? Or wait for explicit save? 
      // Current behavior: saves to disk.
       try {
        context.read<AppData>().repository.saveNote(widget.context.note, widget.context.subFolder, widget.context.folder);
       } catch(e) { debugPrint("Save failed"); }
       
      _editingPost = null;
    } else {
      final post = Post(
        id: DateTime.now().microsecondsSinceEpoch.toString(),
        content: text,
        createdAt: DateTime.now()
      );
      widget.context.note.posts.insert(0, post);
      
       try {
        context.read<AppData>().repository.saveNote(widget.context.note, widget.context.subFolder, widget.context.folder);
       } catch(e) { debugPrint("Save failed"); }
    }


    _controller.clear();
    FocusScope.of(context).unfocus();


    if (mounted) setState(() {});


    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }


  void _cancelEdit() {
    _controller.clear();
    _editingPost = null;
    FocusScope.of(context).unfocus();
    if (mounted) setState(() {});
  }


  void _editPost(Post post) {
    _controller.text = post.content;
    _controller.selection = TextSelection.collapsed(offset: _controller.text.length);
    _editingPost = post;
    FocusScope.of(context).requestFocus(FocusNode());
    if (mounted) setState(() {});
  }


  void _jumpToAndHighlight(Post post) {
    setState(() => _highlightedPostId = post.id);
    
    if (_highlightTimer?.isActive ?? false) _highlightTimer!.cancel();
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightedPostId = null);
    });


    final index = widget.context.note.posts.indexWhere((p) => p.id == post.id);
    if (index != -1 && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _scrollController.animateTo(
          index * 250.0,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    }
  }


  void _showPinnedDialog() {
    final pinned = widget.context.note.posts.where((p) => p.isPinned).toList();
    
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Pinned Posts', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView.builder(
            shrinkWrap: true,
            itemCount: pinned.length,
            itemBuilder: (_, i) {
              final post = pinned[i];
              return ListTile(
                title: Text(post.content.split('\n').first, maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: const Text('Tap to jump & highlight'),
                onTap: () {
                  Navigator.pop(context);
                  _jumpToAndHighlight(post);
                },
              );
            },
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Close'))],
      ),
    );
  }


  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    _editorFocusNode.dispose();
    _keyboardFocusNode.dispose();
    _highlightTimer?.cancel();
    super.dispose();
  }


  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.context.note.name),
        actions: [
          IconButton(icon: const Icon(Icons.push_pin), onPressed: _showPinnedDialog, tooltip: 'View Pinned'),
          IconButton(
            icon: const Icon(Icons.code),
            onPressed: _insertCodeBlock,
            tooltip: 'Insert Code Block'
          ),
                  IconButton(
            icon: const Icon(Icons.format_quote),
            onPressed: _insertQuoteBlock,
            tooltip: 'Insert Quote/Highlight'
          ),
              IconButton(
            icon: const Icon(Icons.grid_view),
            onPressed: () => showRecentNotesDialog(context),
            tooltip: 'Recent Notes',
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              reverse: true,
              padding: const EdgeInsets.all(12),
              itemCount: widget.context.note.posts.length,
              itemBuilder: (_, i) => _buildPostItem(widget.context.note.posts[i]),
            ),
          ),
                  SafeArea(
            top: false,
            child: Container(
              padding: EdgeInsets.only(left: 8, right: 8, bottom: bottomPadding + 4),
              color: Colors.grey[900],
              constraints: const BoxConstraints(maxHeight: 250),
              child: Row(children: [
                              if (_editingPost != null)
                IconButton(
                  icon: const Icon(Icons.close, color: Colors.white70),
                  onPressed: _cancelEdit,
                  tooltip: 'Cancel Edit',
                ),
            Expanded(
              child: RawKeyboardListener(
                focusNode: _keyboardFocusNode,
                autofocus: false,
                onKey: (event) {
                  // On desktop: Enter sends, Shift+Enter inserts newline
                  if ((Platform.isWindows || Platform.isMacOS || Platform.isLinux) &&
                      event is RawKeyDownEvent &&
                      event.logicalKey == LogicalKeyboardKey.enter) {
                    if (event.isShiftPressed) {
                      // Shift+Enter — let it through so TextField inserts a newline
                      return;
                    }
                    // Plain Enter — intercept and send
                    _saveOrAddPost();
                  }
                },
                child: TextField(
                  focusNode: _editorFocusNode,
                  controller: _controller,
                  maxLines: null,
                  minLines: 1,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: _editingPost != null ? 'Editing post...' : 'Type a note...',
                    suffix: Platform.isWindows || Platform.isMacOS || Platform.isLinux
                        ? const Text('Enter to send · Shift+Enter for newline', style: TextStyle(color: Colors.grey, fontSize: 10))
                        : null,
                  ),
                ),
              ),
            ),
                              if (_editingPost != null)
                IconButton(
                  icon: const Icon(Icons.check, color: Colors.white70),
                  onPressed: _saveOrAddPost,
                  tooltip: 'Save Edit',
                )
              else
                IconButton(icon: const Icon(Icons.send, color: Colors.white70), onPressed: _saveOrAddPost),
            ]),
            ),
          ),
        ],
      ),
    );
  }


  Widget _buildPostItem(Post post) {
    final isHighlighted = post.id == _highlightedPostId;


    return Dismissible(
      key: ValueKey(post.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: Colors.red[700],
        alignment: Alignment.centerLeft,
        padding: const EdgeInsets.only(left: 20.0),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (direction) {
        widget.context.note.posts.removeWhere((p) => p.id == post.id);
        setState(() {});
        
         try {
           context.read<AppData>().repository.saveNote(widget.context.note, widget.context.subFolder, widget.context.folder);
         } catch(e) { debugPrint("Delete save failed"); }


        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Post deleted'), duration: Duration(seconds: 1)),
          );
        }
      },
      child: GestureDetector(
        onTap: () => _copyToClipboard(post.content),
        onLongPress: () => _editPost(post),
        onSecondaryTap: (Platform.isWindows || Platform.isMacOS || Platform.isLinux) ? () => _editPost(post) : null,
        child: Card(
          margin: const EdgeInsets.only(bottom: 10),
          color: isHighlighted ? Colors.grey[800] : Colors.grey[850],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide.none,
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(mainAxisAlignment: MainAxisAlignment.end, children: [
                IconButton(
                  icon: Icon(Icons.push_pin, color: post.isPinned ? Colors.amber : Colors.grey[600]),
                  onPressed: () async {
                    await context.read<AppData>().togglePin(widget.context, post);
                    if (mounted) setState(() {});
                  },
                ),
              ]),
                      MarkdownBody(
                data: _prepareMarkdownContent(post.content),
                styleSheet: MarkdownStyleSheet(
                  p: const TextStyle(height: 1.3),
                  a: const TextStyle(color: Colors.blueAccent, decoration: TextDecoration.underline),
                                  tableBorder: TableBorder.all(color: Colors.white, width: 1),
                  tableCellsPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  blockquoteDecoration: BoxDecoration(
                    border: Border(left: BorderSide(color: Colors.grey[700]!, width: 4)),
                    color: Colors.transparent,
                  ),
                  blockquotePadding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                onTapLink: (text, href, title) async {
                  if (href == null || href.isEmpty) return;
                  try {
                    final uri = Uri.parse(href);
                    if (await canLaunchUrl(uri)) {
                      await launchUrl(uri, mode: LaunchMode.externalApplication);
                    } else {
                      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not open $href')));
                    }
                  } catch (e) { debugPrint('Link error: $e'); }
                },
              ),
              const SizedBox(height: 4),
              Text('${post.createdAt.hour}:${post.createdAt.minute.toString().padLeft(2, '0')}', style: TextStyle(color: Colors.grey[600], fontSize: 12)),
            ]),
          ),
        ),
      ),
    );
  }
}



class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key});


  @override
  Widget build(BuildContext context) {
    final data = context.watch<AppData>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () async {
              await data.retryStorageInit();
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Folders refreshed'), duration: Duration(seconds: 1)),
                );
              }
            },
            tooltip: 'Refresh Folders',
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Save Location', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            decoration: InputDecoration(hintText: 'Current save location'),
            controller: TextEditingController(text: data.storageBackend.formatPath(data.savePath)),
            readOnly: true,
          ),
          const SizedBox(height: 12),
          ElevatedButton.icon(
            onPressed: () async {
              await data.pickAndInitializeFolder();
            },
            icon: const Icon(Icons.folder_open),
            label: const Text('Change Folder'),
            style: ElevatedButton.styleFrom(
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
          const SizedBox(height: 8),
          // Allow manual path entry as fallback (desktop only)
          if (data.isDesktop) ...[
            const SizedBox(height: 16),
            const Text('Or enter path manually', style: TextStyle(color: Colors.grey)),
            const SizedBox(height: 8),
            TextField(
              decoration: InputDecoration(hintText: 'Enter directory path'),
              controller: TextEditingController(text: data.savePath),
              onSubmitted: (val) => data.updateSavePath(val.trim()),
            ),
          ],
          const SizedBox(height: 24),
          Text(
            data.isAndroid
                ? '• Your notes are stored as plain .md files in the folder you selected\n'
                    '• This location survives app reinstalls\n'
                    '• You can change it anytime from here'
                : '• Your notes are stored as plain .md files in the folder you selected\n'
                    '• You can change the save location anytime',
            style: const TextStyle(color: Colors.grey, height: 1.5),
          ),
          const SizedBox(height: 24),
          if (!data.storageReady)
            ElevatedButton.icon(
              onPressed: () async {
                await data.pickAndInitializeFolder();
              },
              icon: const Icon(Icons.folder_open),
              label: const Text('Select a Folder'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red[700],
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
        ]),
      ),
    );
  }
}



class _OnboardingScreenState extends State<OnboardingScreen> {
  final TextEditingController _pathController = TextEditingController();


  @override
  void dispose() {
    _pathController.dispose();
    super.dispose();
  }


  Widget build(BuildContext context) {
    return Scaffold(
      body: Consumer<AppData>(
        builder: (ctx, data, _) {
          if (data.onboardingCompleted) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Navigator.of(ctx).pushReplacement(
                MaterialPageRoute(builder: (_) => const HomeScreen()),
              );
            });
            return Container();
          }


          final isAndroid = data.isAndroid;

          void _applyManualPath() {
            final val = _pathController.text.trim();
            if (val.isNotEmpty) {
              data.updateSavePath(val);
              data.retryStorageInit().then((_) {
                if (data.storageReady) {
                  data.completeOnboarding();
                }
              });
            }
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.drive_folder_upload_rounded,
                    size: 120,
                    color: Colors.grey[600],
                  ),
                  const SizedBox(height: 32),


                  const Text(
                    'Welcome to darkslip',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),


                  Text(
                    isAndroid
                        ? 'darkslip saves your notes as markdown files on your device. To get started, choose a folder for your notes.'
                        : 'darkslip saves your notes as markdown files. To get started, choose where your notes will be stored.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 48),


                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        await data.pickAndInitializeFolder();
                        if (data.storageReady) {
                          await data.completeOnboarding();
                        }
                      },
                      icon: const Icon(Icons.folder_open),
                      label: Text(
                        isAndroid ? 'Choose a Folder' : 'Use Default Location',
                        style: const TextStyle(fontSize: 16),
                      ),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black87,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  if (data.isDesktop) ...[
                    const SizedBox(height: 16),
                    const Text('Or enter a path manually below', style: TextStyle(color: Colors.grey)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _pathController,
                            decoration: const InputDecoration(hintText: 'e.g. C:\\Users\\You\\Documents\\darkslip'),
                            onSubmitted: (_) => _applyManualPath(),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _applyManualPath,
                          child: const Text('Go'),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 48),


                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: Colors.grey[850],
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.grey[700]!),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: const [
                            Icon(Icons.info_outline, size: 20, color: Colors.blue),
                            SizedBox(width: 8),
                            Text(
                              'Why is this needed?',
                              style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white70),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        Text(
                          isAndroid
                              ? 'Your notes are stored as plain .md files in the folder you choose. This means your data is always accessible, even after reinstalling the app.'
                              : 'Your notes are stored as plain .md files in the folder you choose, so they remain accessible outside the app.',
                          style: const TextStyle(color: Colors.grey, height: 1.5),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}


class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});


  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}



// ================= APP ENTRY =================


void main() {
  WidgetsFlutterBinding.ensureInitialized();
  
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.manual, overlays: [SystemUiOverlay.top, SystemUiOverlay.bottom]);
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);


  runApp(ChangeNotifierProvider(create: (_) => AppData()..init(), child: const DarkSlipApp()));
}


class DarkSlipApp extends StatelessWidget {
  const DarkSlipApp({super.key});


  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'darkslip',
      debugShowCheckedModeBanner: false,
      theme: darkSlipTheme(),
      home: Consumer<AppData>(
        builder: (ctx, data, _) {
          // Show onboarding if never completed OR if storage is unavailable
          // (handles reinstall + permission revocation scenarios)
          if (!data.onboardingCompleted || !data.storageReady) {
            return const OnboardingScreen();
          }
          return const HomeScreen();
        },
      ),
    );
  }
}
