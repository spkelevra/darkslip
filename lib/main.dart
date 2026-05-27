import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:permission_handler/permission_handler.dart';

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
  String id; // Mutable to allow ID updates on rename
  String name;
  List<Note> notes = [];

  SubFolder({required this.id, required this.name});
}

class Folder {
  String id; // Mutable to allow ID updates on rename
  String name;
  List<SubFolder> subFolders = [];
  List<Note> notes = [];

  Folder({required this.id, required this.name});
}

// Recent Note Model for tracking history
class RecentNote {
  final String folderName;
  final String? subFolderName; // null means note is directly in the folder
  final String noteId;
  final String noteName;
  final DateTime accessedAt;

  RecentNote({
    required this.folderName,
    this.subFolderName,
    required this.noteId,
    required this.noteName,
    required this.accessedAt,
  });

  // Serialization methods
  String toJson() => '$folderName|${subFolderName ?? ''}|$noteId|$noteName|$accessedAt';

  factory RecentNote.fromJson(String json) {
    final parts = json.split('|');
    if (parts.length != 5) throw FormatException('Invalid format');
    return RecentNote(
      folderName: parts[0],
      subFolderName: parts[1].isEmpty ? null : parts[1],
      noteId: parts[2],
      noteName: parts[3],
      accessedAt: DateTime.parse(parts[4]),
    );
  }
}

// ================= STATE MANAGEMENT =================

class AppData extends ChangeNotifier {
  List<Folder> folders = [];
  String savePath = '';
  String appName = 'darkslip';
  Set<String> expandedTiles = {};
  bool _initialized = false;
  bool _storageReady = false;
  bool _onboardingCompleted = false;
  String? _lastError;

  // Recent Notes Tracking
  List<RecentNote> recentNotes = [];

  bool get storageReady => _storageReady;
  bool get onboardingCompleted => _onboardingCompleted;

    Future<void> addRecentNote(
      String folderName, String? subFolderName, String noteId, String noteName) async {
    recentNotes.removeWhere((r) => r.noteId == noteId);
    recentNotes.insert(0, RecentNote(
      folderName: folderName,
      subFolderName: subFolderName,
      noteId: noteId,
      noteName: noteName,
      accessedAt: DateTime.now(),
    ));
    
    // Keep only last 9 items
    if (recentNotes.length > 9) recentNotes.removeLast();

    await _saveRecentNotes();
    notifyListeners();
  }

    Future<bool> _checkStorageAccess() async {
    try {
      Directory(savePath).createSync(recursive: true);
      final testFile = File('$savePath/.write_test');
      await testFile.writeAsString('ok');
      await testFile.delete();
      return true;
    } catch (e) {
      _lastError = 'Storage not accessible.';
      return false;
    }
  }

    Future<void> init() async {
    if (_initialized) return;
    final prefs = await SharedPreferences.getInstance();

    appName = prefs.getString('app_name') ?? 'darkslip';
    savePath = prefs.getString('save_path') ?? '/storage/emulated/0/Documents/darkslip';
    
    // Load saved expansion state
    expandedTiles.addAll(prefs.getStringList('expanded_tiles') ?? []);
    
    await _loadRecentNotes();

    // Check if user has completed onboarding before
    _onboardingCompleted = prefs.getBool('onboarding_completed') ?? false;

    _storageReady = await _checkStorageAccess();

    if (_storageReady) {
      await syncFromDisk();
    }
    _initialized = true;
    notifyListeners();
  }

  Future<void> completeOnboarding() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('onboarding_completed', true);
    _onboardingCompleted = true;
    notifyListeners();
  }

  Future<void> retryStorageInit() async {
    _storageReady = await _checkStorageAccess();
    if (_storageReady) {
      await syncFromDisk();
    }
    notifyListeners();
  }

    Future<void> requestStoragePermission() async {
    try {
      final status = await Permission.manageExternalStorage.request();
      if (status.isGranted) {
        _lastError = null;
        // Retry storage check after permission granted
        await retryStorageInit();
      } else if (status.isDenied) {
        _lastError = 'Storage permission denied. Please grant access in Settings.';
      } else if (status.isPermanentlyDenied) {
        _lastError = 'Permission permanently denied. Please enable it in App Settings > Permissions.';
      }
    } catch (e) {
      _lastError = 'Failed to request permission: $e';
    }
    notifyListeners();
  }

  void updateSavePath(String newPath) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('save_path', newPath);
    savePath = newPath;
    await syncFromDisk();
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

  // File System Operations

  Future<void> syncFromDisk() async {
    try {
      final dir = Directory(savePath);
      if (!await dir.exists()) return;

      folders.clear();
      
            await for (var entity in dir.list()) {
        if (entity is Directory) {
          final folderName = entity.path.split(Platform.pathSeparator).last;
          final folder = Folder(id: 'f_$folderName', name: folderName);

          // Scan for notes directly in the folder AND subfolders
          await for (var sfEntity in entity.list()) {
            if (sfEntity is Directory) {
              final sfName = sfEntity.path.split(Platform.pathSeparator).last;
              final subFolder = SubFolder(id: 'sf_${folder.name}_$sfName', name: sfName);

              await for (var noteEntity in sfEntity.list()) {
                if (noteEntity is File && noteEntity.path.endsWith('.md')) {
                  final noteName = noteEntity.path.split(Platform.pathSeparator).last.replaceAll('.md', '');
                  final note = Note(id: 'n_${noteName.hashCode}_${sfName.hashCode}', name: noteName);
                  await loadNote(note, subFolder, folder);
                  subFolder.notes.add(note);
                }
              }
              folder.subFolders.add(subFolder);
            } else if (sfEntity is File && sfEntity.path.endsWith('.md')) {
              // Note directly in the folder (no subfolder)
              final noteName = sfEntity.path.split(Platform.pathSeparator).last.replaceAll('.md', '');
              final note = Note(id: 'n_${noteName.hashCode}_${folder.name.hashCode}', name: noteName);
              await loadNote(note, null, folder);
              folder.notes.add(note);
            }
          }
          folders.add(folder);
        }
      }
    } catch (e) {
      _lastError = 'Failed to load directory: $e';
      debugPrint(_lastError);
    }
  }

    Future<String> _getNoteFilePath(Note note, SubFolder? subFolder, Folder folder) async {
    final dir = subFolder != null
        ? Directory('$savePath/${folder.name}/${subFolder.name}')
        : Directory('$savePath/${folder.name}');
    if (!await dir.exists()) await dir.create(recursive: true);
    return '${dir.path}/${note.name}.md';
  }

  Future<void> saveNote(Note note, SubFolder? subFolder, Folder folder) async {
    try {
      final path = await _getNoteFilePath(note, subFolder, folder);
      String mdContent = '';
      
      for (var post in note.posts) {
        if (post.isPinned) mdContent += '<!-- PINNED -->\n';
        mdContent += '${post.content}\n---\n\n';
      }
      
      await File(path).writeAsString(mdContent);
    } catch (e) { 
      _lastError = 'Save failed: $e'; 
      debugPrint(_lastError); 
    } finally {
      notifyListeners();
    }
  }

  Future<void> loadNote(Note note, SubFolder? subFolder, Folder folder) async {
    try {
      final path = await _getNoteFilePath(note, subFolder, folder);
      final file = File(path);
      if (!await file.exists()) return;

      String content = await file.readAsString();
      // Split by separator line
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
      _lastError = 'Failed to load note: $e';
    } finally {
      notifyListeners();
    }
  }

    Future<void> togglePin(Note note, Post post, SubFolder? subFolder, Folder folder) async {
    post.isPinned = !post.isPinned;
    await saveNote(note, subFolder, folder);
  }

  // CRUD Operations for Folders/SubFolders/Notes

  Future<void> createFolder(String name) async {
    folders.add(Folder(id: 'f_$name', name: name));
    notifyListeners();
  }

  Future<void> renameFolder(Folder folder, String newName) async {
    try {
      final oldDir = Directory('$savePath/${folder.name}');
      if (await oldDir.exists()) await oldDir.rename('$savePath/$newName');
      
      expandedTiles.remove(folder.id);
      folder.id = 'f_$newName';
      folder.name = newName;
    } catch (e) { 
      _lastError = 'Rename failed: $e'; 
      debugPrint(_lastError); 
    }
    notifyListeners();
  }

  Future<void> deleteFolder(Folder folder) async {
    try {
      final dir = Directory('$savePath/${folder.name}');
      if (await dir.exists()) await dir.delete(recursive: true);
      
      folders.removeWhere((f) => f.id == folder.id);
      expandedTiles.remove(folder.id);
    } catch (e) { 
      _lastError = 'Delete failed: $e'; 
      debugPrint(_lastError); 
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
      final oldDir = Directory('$savePath/${parentFolder.name}/${subFolder.name}');
      if (await oldDir.exists()) await oldDir.rename('$savePath/${parentFolder.name}/$newName');
      
      expandedTiles.remove(subFolder.id);
      subFolder.id = 'sf_${parentFolder.name}_$newName';
      subFolder.name = newName;
    } catch (e) { 
      _lastError = 'Rename failed: $e'; 
      debugPrint(_lastError); 
    }
    notifyListeners();
  }

  Future<void> deleteSubFolder(SubFolder subFolder, Folder parentFolder) async {
    try {
      final dir = Directory('$savePath/${parentFolder.name}/${subFolder.name}');
      if (await dir.exists()) await dir.delete(recursive: true);
      
      parentFolder.subFolders.removeWhere((sf) => sf.id == subFolder.id);
      expandedTiles.remove(subFolder.id);
    } catch (e) { 
      _lastError = 'Delete failed: $e'; 
      debugPrint(_lastError); 
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
    await saveNote(newNote, subFolder, folder);
    notifyListeners();
  }

    Future<void> renameNote(Note note, String newName, Folder folder, {SubFolder? subFolder}) async {
    try {
      final oldPath = await _getNoteFilePath(note, subFolder, folder);
      final newDir = subFolder != null
          ? Directory('$savePath/${folder.name}/${subFolder.name}')
          : Directory('$savePath/${folder.name}');
      if (!await newDir.exists()) await newDir.create(recursive: true);
      
      final newPath = '${newDir.path}/$newName.md';
      final oldFile = File(oldPath);
      
      if (await oldFile.exists()) await oldFile.rename(newPath);
      note.name = newName;
    } catch (e) { 
      _lastError = 'Rename failed: $e'; 
      debugPrint(_lastError); 
    }
    notifyListeners();
  }

  Future<void> deleteNote(Note note, Folder folder, {SubFolder? subFolder}) async {
    try {
      final path = await _getNoteFilePath(note, subFolder, folder);
      if (await File(path).exists()) await File(path).delete();
      
      if (subFolder != null) {
        subFolder.notes.removeWhere((n) => n.id == note.id);
      } else {
        folder.notes.removeWhere((n) => n.id == note.id);
      }
    } catch (e) { 
      _lastError = 'Delete failed: $e'; 
      debugPrint(_lastError); 
    }
    notifyListeners();
  }

  void updatePostContent(Post post, String newContent) {
    post.content = newContent;
    notifyListeners();
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

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  // Helper to show standard create/rename dialogs
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

  void _showRecentNotesDialog(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Colors.grey[900],
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Recent Notes', style: TextStyle(color: Colors.white)),
        content: SizedBox(
          width: double.maxFinite,
          height: 340,
          child: Consumer<AppData>(
            builder: (ctx, data, _) => GridView.count(
              crossAxisCount: 3,
              mainAxisSpacing: 10,
              crossAxisSpacing: 10,
              children: List.generate(9, (index) {
                if (index < data.recentNotes.length) {
                  final recent = data.recentNotes[index];
                  return _buildRecentTile(recent, ctx);
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
            ),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Close')),
        ],
      ),
    );
  }

    Widget _buildRecentTile(RecentNote recent, BuildContext ctx) {
    return GestureDetector(
      onTap: () {
        final data = ctx.read<AppData>();

        // Find the note in the current state to navigate
        for (var f in data.folders) {
          if (f.name == recent.folderName) {
            // If subFolder is specified, search there
            if (recent.subFolderName != null) {
              for (var sf in f.subFolders) {
                if (sf.name == recent.subFolderName) {
                  for (var n in sf.notes) {
                    if (n.id == recent.noteId) {
                      Navigator.pop(ctx);
                      data.addRecentNote(f.name, sf.name, n.id, n.name);
                      Navigator.push(ctx, MaterialPageRoute(builder: (_) => NoteScreen(folder: f, subFolder: sf, note: n)));
                      return;
                    }
                  }
                }
              }
            } else {
              // Search in folder-level notes
              for (var n in f.notes) {
                if (n.id == recent.noteId) {
                  Navigator.pop(ctx);
                  data.addRecentNote(f.name, null, n.id, n.name);
                  Navigator.push(ctx, MaterialPageRoute(builder: (_) => NoteScreen(folder: f, note: n)));
                  return;
                }
              }
            }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Consumer<AppData>(
          builder: (ctx, data, _) => GestureDetector(
            onLongPress: () {
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
            },
            child: Text(data.appName),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.grid_view),
            onPressed: () => _showRecentNotesDialog(context),
            tooltip: 'Recent Notes',
          ),
          Consumer<AppData>(
            builder: (ctx, data, _) => IconButton(
              icon: const Icon(Icons.refresh),
              onPressed: () async {
                await data.syncFromDisk();
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Folders refreshed'), duration: Duration(seconds: 1)),
                  );
                }
              },
              tooltip: 'Refresh Folders',
            ),
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
          if (data._lastError != null) {
            return Center(child: Text('Storage Error:\n${data._lastError}', textAlign: TextAlign.center, style: const TextStyle(color: Colors.red)));
          }
          
          return ListView.builder(
            itemCount: data.folders.length,
            itemBuilder: (_, i) => _buildFolderTile(ctx, data, data.folders[i]),
          );
        },
      ),
    );
  }

    // Extracted Folder Tile Builder for cleaner code
  Widget _buildFolderTile(BuildContext ctx, AppData data, Folder folder) {
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
          ...folder.notes.map((note) => _buildNoteTile(ctx, data, folder, note)),
          if (folder.subFolders.isEmpty && folder.notes.isEmpty)
            const Padding(padding: EdgeInsets.all(16), child: Text('No subfolders or notes yet.', style: TextStyle(color: Colors.grey))),
          ...folder.subFolders.map((sf) => _buildSubFolderTile(ctx, data, folder, sf)),
        ],
      ),
    );
  }

  // Extracted SubFolder Tile Builder
  Widget _buildSubFolderTile(BuildContext ctx, AppData data, Folder parentFolder, SubFolder subFolder) {
    return GestureDetector(
      onLongPress: () => _showItemMenu(ctx, 'SubFolder',
        onRename: () => _showInputDialog(ctx, 'Rename SubFolder', TextEditingController(text: subFolder.name), (name) => data.renameSubFolder(subFolder, parentFolder, name)),
        onDelete: () {
          showDialog(context: ctx, builder: (_) => AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text('Delete SubFolder?', style: TextStyle(color: Colors.white)),
            content: Text('This will permanently delete "${subFolder.name}" and all its notes.', style: const TextStyle(color: Colors.white70)),
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
          ...subFolder.notes.map((note) => _buildNoteTile(ctx, data, parentFolder, note, subFolder: subFolder)),
        ],
      ),
    );
  }

    // Extracted Note Tile Builder (subFolder is optional for folder-level notes)
  Widget _buildNoteTile(BuildContext ctx, AppData data, Folder folder, Note note, {SubFolder? subFolder}) {
    return GestureDetector(
      onLongPress: () => _showItemMenu(ctx, 'Note',
        onRename: () => _showInputDialog(ctx, 'Rename Note', TextEditingController(text: note.name), (name) => data.renameNote(note, name, folder, subFolder: subFolder)),
        onDelete: () {
          showDialog(context: ctx, builder: (_) => AlertDialog(
            backgroundColor: Colors.grey[900],
            title: const Text('Delete Note?', style: TextStyle(color: Colors.white)),
            content: Text('This will permanently delete "${note.name}" and its file.', style: const TextStyle(color: Colors.white70)),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
              TextButton(
                onPressed: () { 
                  data.deleteNote(note, folder, subFolder: subFolder); 
                  Navigator.pop(ctx); 
                }, 
                style: ButtonStyle(foregroundColor: WidgetStateProperty.all(Colors.red)), 
                child: const Text('Delete')
              ),
            ],
          ));
        }
      ),
      child: ListTile(
        leading: const Icon(Icons.note_outlined, color: Colors.white70),
        title: Text(note.name),
        subtitle: Text('${note.posts.length} posts'),
        onTap: () {
          data.addRecentNote(folder.name, subFolder?.name, note.id, note.name);
          Navigator.push(ctx, MaterialPageRoute(builder: (_) => NoteScreen(folder: folder, subFolder: subFolder, note: note)));
        },
      ),
    );
  }
}

class NoteScreen extends StatefulWidget {
  final Folder folder;
  final SubFolder? subFolder; // null means note is directly in the folder
  final Note note;
  
  const NoteScreen({super.key, required this.folder, this.subFolder, required this.note});

  @override
  State<NoteScreen> createState() => _NoteScreenState();
}

class _NoteScreenState extends State<NoteScreen> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String? _highlightedPostId;
  Timer? _highlightTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadNote());
  }

  Future<void> _loadNote() async {
    await context.read<AppData>().loadNote(widget.note, widget.subFolder, widget.folder);
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

    // Formatting Helpers

  /// Prepares markdown content for display. Preserves single newlines within
  /// markdown tables (to keep table structure intact) while converting single
  /// newlines to double newlines in regular text (for proper paragraph spacing).
  String _prepareMarkdownContent(String content) {
    final lines = content.split('\n');
    final result = <String>[];
    bool inTable = false;

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i];
      // A table line starts with | and contains at least one more |
      final isTableLine = RegExp(r'^\s*\|.*\|\s*$').hasMatch(line);
      // A table separator line like |---|---|
      final isSeparatorLine = RegExp(r'^\s*\|[\s\-:|]+\|$').hasMatch(line);

      if (isTableLine || isSeparatorLine) {
        inTable = true;
        result.add(line);
      } else if (inTable && line.trim().isEmpty) {
        // Blank line after table — end the table context
        inTable = false;
        result.add(''); // keep one blank line as paragraph separator
      } else if (inTable) {
        // We're inside a table but hit a non-table, non-blank line.
        // This is unlikely but treat it as ending the table.
        inTable = false;
        result.add('');
        result.add(line);
      } else {
        // Regular text — add extra blank line for paragraph spacing
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

    void _insertTableBlock() {
    final currentText = _controller.text;
    final selection = _controller.selection;

    const tableSyntax = '| Column 1 | Column 2 | Column 3 |\n|----------|----------|----------|\n| Cell 1   | Cell 2   | Cell 3   |';

    // Use the valid cursor position, defaulting to end of text if selection is invalid (-1)
    final insertPos = selection.isValid ? selection.start : currentText.length;

    String newText;
    int newCursorPos;

    if (selection.isCollapsed) {
      newText = currentText.replaceRange(insertPos, insertPos, tableSyntax);
      newCursorPos = insertPos + 14; // position cursor in "Column 1" area
    } else {
      newText = currentText.replaceRange(selection.start, selection.end, tableSyntax);
      newCursorPos = selection.start + 14;
    }

    _controller.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newCursorPos),
    );

    FocusScope.of(context).requestFocus(FocusNode());
  }

    void _insertCodeBlock() {
    final currentText = _controller.text;
    final selection = _controller.selection;

    const codeBlockSyntax = '```\n\n```';

    // Use the valid cursor position, defaulting to end of text if selection is invalid (-1)
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

    // Use the valid cursor position, defaulting to end of text if selection is invalid (-1)
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

  void _addPost() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    
    final post = Post(
      id: DateTime.now().microsecondsSinceEpoch.toString(), 
      content: text, 
      createdAt: DateTime.now()
    );
    
    widget.note.posts.insert(0, post);
    _controller.clear();
    FocusScope.of(context).unfocus(); 
    
    if (mounted) setState(() {}); 
    context.read<AppData>().saveNote(widget.note, widget.subFolder, widget.folder);
    
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.jumpTo(0);
      }
    });
  }

  void _editPost(Post post) {
    final ctrl = TextEditingController(text: post.content);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: Colors.grey[900],
        title: const Text('Edit Post', style: TextStyle(color: Colors.white)),
        content: TextField(controller: ctrl, maxLines: 6, decoration: const InputDecoration(hintText: 'Markdown supported')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(
            onPressed: () {
              context.read<AppData>().updatePostContent(post, ctrl.text.trim());
              context.read<AppData>().saveNote(widget.note, widget.subFolder, widget.folder);
              if (mounted) setState(() {});
              Navigator.pop(context);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _jumpToAndHighlight(Post post) {
    setState(() => _highlightedPostId = post.id);
    
    if (_highlightTimer?.isActive ?? false) _highlightTimer!.cancel();
    _highlightTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _highlightedPostId = null);
    });

    final index = widget.note.posts.indexWhere((p) => p.id == post.id);
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
    final pinned = widget.note.posts.where((p) => p.isPinned).toList();
    
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
    _highlightTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bottomPadding = MediaQuery.of(context).padding.bottom;
    
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.note.name),
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
            icon: const Icon(Icons.table_chart),
            onPressed: _insertTableBlock,
            tooltip: 'Insert Table'
          ),
          IconButton(icon: const Icon(Icons.settings), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => SettingsScreen()))),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: ListView.builder(
              controller: _scrollController,
              reverse: true,
              padding: const EdgeInsets.all(12),
              itemCount: widget.note.posts.length,
              itemBuilder: (_, i) => _buildPostItem(widget.note.posts[i]),
            ),
          ),
          SafeArea(
            top: false,
            child: Container(
              padding: EdgeInsets.only(left: 8, right: 8, bottom: bottomPadding + 4),
              color: Colors.grey[900],
              child: Row(children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    maxLines: null,
                    minLines: 1,
                    keyboardType: TextInputType.multiline,
                    textInputAction: TextInputAction.newline,
                    decoration: const InputDecoration(hintText: 'Type a note...'),
                  ),
                ),
                IconButton(icon: const Icon(Icons.send, color: Colors.white70), onPressed: _addPost),
              ]),
            ),
          ),
        ],
      ),
    );
  }

  // Extracted Post Item Builder
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
        widget.note.posts.removeWhere((p) => p.id == post.id);
        setState(() {});
        context.read<AppData>().saveNote(widget.note, widget.subFolder, widget.folder);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Post deleted'), duration: Duration(seconds: 1)),
          );
        }
      },
      child: GestureDetector(
        onTap: () => _copyToClipboard(post.content),
        onLongPress: () => _editPost(post),
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
                    await context.read<AppData>().togglePin(widget.note, post, widget.subFolder, widget.folder);
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
      appBar: AppBar(title: const Text('Settings')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Save Location', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          TextField(
            decoration: InputDecoration(hintText: 'Enter directory path'),
            controller: TextEditingController(text: data.savePath),
            onSubmitted: (val) => data.updateSavePath(val.trim()),
          ),
          const SizedBox(height: 24),
          const Text(
            '• Files are saved to /Documents/darkslip by default\n'
            '• This location survives app reinstalls',
            style: TextStyle(color: Colors.grey, height: 1.5),
          ),
        ]),
      ),
    );
  }
}

class OnboardingScreen extends StatelessWidget {
  const OnboardingScreen({super.key});

  

    @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Consumer<AppData>(
        builder: (ctx, data, _) {
          if (data.onboardingCompleted) {
            // Onboarding done, navigate to home
            WidgetsBinding.instance.addPostFrameCallback((_) {
              Navigator.of(ctx).pushReplacement(
                MaterialPageRoute(builder: (_) => const HomeScreen()),
              );
            });
            return Container();
          }

          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(24.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Icon
                  Icon(
                    Icons.drive_folder_upload_rounded,
                    size: 120,
                    color: Colors.grey[600],
                  ),
                  const SizedBox(height: 32),

                  // Title
                  const Text(
                    'Welcome to darkslip',
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Description
                  Text(
                    'darkslip saves your notes as markdown files on your device. To get started, we need storage access.',
                    textAlign: TextAlign.center,
                    style: TextStyle(fontSize: 16, color: Colors.grey[400]),
                  ),
                  const SizedBox(height: 48),

                                    // Primary action button
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: () async {
                        await data.requestStoragePermission();
                        await data.completeOnboarding();
                      },
                      icon: const Icon(Icons.security),
                      label: const Text('Grant Storage Access', style: TextStyle(fontSize: 16)),
                      style: ElevatedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        backgroundColor: Colors.white,
                        foregroundColor: Colors.black87,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),

                  // Retry button - check if storage was granted externally
                  SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      onPressed: () async {
                        await data.retryStorageInit();
                        await data.completeOnboarding();
                      },
                      icon: const Icon(Icons.refresh),
                      label: const Text('Check Again', style: TextStyle(fontSize: 16)),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        side: BorderSide(color: Colors.grey[700]!),
                        foregroundColor: Colors.white70,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 48),

                  // Info card
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
                        const Text(
                          'Your notes are stored as plain .md files in /Documents/darkslip. This means your data is always accessible, even after reinstalling the app.',
                          style: TextStyle(color: Colors.grey, height: 1.5),
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
          if (!data.onboardingCompleted) {
            return const OnboardingScreen();
          }
          return const HomeScreen();
        },
      ),
    );
  }
}