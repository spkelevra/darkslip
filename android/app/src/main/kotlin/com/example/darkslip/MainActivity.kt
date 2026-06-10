package com.example.darkslip

import android.app.Activity
import android.content.ContentResolver
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private lateinit var channel: MethodChannel
    private var treeUri: Uri? = null
    private var pendingResult: MethodChannel.Result? = null

    companion object {
        private const val REQUEST_PICK_FOLDER = 1001
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val messenger = flutterEngine?.dartExecutor?.binaryMessenger
            ?: throw IllegalStateException("Flutter engine not available")
        channel = MethodChannel(messenger, "darkslip/storage")
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "getSavedTreeUri" -> {
                    val prefs = getPreferences(MODE_PRIVATE)
                    val savedUri = prefs.getString("tree_uri", null)
                    result.success(treeUri?.toString() ?: savedUri)
                }
                "pickDirectory" -> launchFolderPicker(result)
                "checkAccess" -> handleCheckAccess(call.argument("basePath"), result)
                "listDirectory" -> handleListDirectory(
                    call.argument("basePath"),
                    call.argument("relativePath"),
                    result
                )
                "readFile" -> handleReadFile(
                    call.argument("basePath"),
                    call.argument("relativePath"),
                    result
                )
                "writeFile" -> {
                    val content = call.argument<String>("content") ?: ""
                    handleWriteFile(call.argument("basePath"), call.argument("relativePath"), content, result)
                }
                "createDirectory" -> handleCreateDirectory(
                    call.argument("basePath"),
                    call.argument("relativePath"),
                    result
                )
                "deleteEntry" -> handleDeleteEntry(
                    call.argument("basePath"),
                    call.argument("relativePath"),
                    result
                )
                "renameEntry" -> handleRenameEntry(
                    call.argument("basePath"),
                    call.argument("oldRelativePath"),
                    call.argument("newName"),
                    result
                )
                else -> result.notImplemented()
            }
        }

        // Restore persisted URI if available
        val prefs = getPreferences(MODE_PRIVATE)
        val savedUri = prefs.getString("tree_uri", null)
        if (savedUri != null && treeUri == null) {
            try {
                treeUri = Uri.parse(savedUri)
            } catch (_: Exception) { /* ignore */ }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == REQUEST_PICK_FOLDER && resultCode == Activity.RESULT_OK) {
            val uri = data?.data
            if (uri != null) {
                contentResolver.takePersistableUriPermission(
                    uri,
                    Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION
                )
                treeUri = uri
                // Persist so it survives process death
                val prefs = getPreferences(MODE_PRIVATE)
                prefs.edit().putString("tree_uri", uri.toString()).apply()

                channel.invokeMethod("onFolderSelected", uri.toString())
            } else {
                channel.invokeMethod("onFolderSelected", null as Any?)
            }
        } else {
            channel.invokeMethod("onFolderSelected", null as Any?)
        }
    }

    // ================== PICKER ==================

    private fun launchFolderPicker(result: MethodChannel.Result) {
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT_TREE).apply {
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
        startActivityForResult(intent, REQUEST_PICK_FOLDER)
        result.success(null) // Async — result comes via onFolderSelected callback
    }

    // ================== URI HELPERS ==================

    /**
     * Walk down from tree root to target path, resolving each segment by querying children.
     * Avoids colon-ambiguity when treeDocId contains colons. Filters by MIME type when needed.
     */
    private fun buildChildUri(treeUri: Uri, relativePath: String?, mustBeDirectory: Boolean = false): Uri {
        if (relativePath.isNullOrEmpty()) return DocumentsContract.buildDocumentUriUsingTree(
            treeUri, DocumentsContract.getTreeDocumentId(treeUri)
        )

        val parts = relativePath.split("/")
        var currentDocId = DocumentsContract.getTreeDocumentId(treeUri)

        for ((i, part) in parts.withIndex()) {
            val isDirOnly = i < parts.size - 1 || mustBeDirectory
            val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, currentDocId)
            val found = contentResolver.query(childUri, null, null, null, null)?.use { cursor ->
                val nameIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val docIdIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                val typeIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                var matchedDocId: String? = null
                while (cursor.moveToNext()) {
                    if (cursor.getString(nameIdx) == part) {
                        if (isDirOnly && cursor.getString(typeIdx) != DocumentsContract.Document.MIME_TYPE_DIR) continue
                        matchedDocId = cursor.getString(docIdIdx)
                        break
                    }
                }
                matchedDocId
            }
            if (found == null) throw IllegalArgumentException("Cannot find child under " + currentDocId)
            currentDocId = found
        }

        return DocumentsContract.buildDocumentUriUsingTree(treeUri, currentDocId)
    }


    // ================== STORAGE OPERATIONS ==================

    private fun handleCheckAccess(basePath: String?, result: MethodChannel.Result) {
        try {
            val uri = Uri.parse(basePath!!)
            contentResolver.query(
                DocumentsContract.buildChildDocumentsUriUsingTree(uri, DocumentsContract.getTreeDocumentId(uri)),
                null, null, null, null
            )?.close()
            result.success(true)
        } catch (e: Exception) {
            result.success(false)
        }
    }

    private fun handleListDirectory(basePath: String?, relativePath: String?, result: MethodChannel.Result) {
        try {
            val treeUri = Uri.parse(basePath!!)
            // When listing root, use treeDocId directly. For subdirs, resolve via buildChildUri.
            val parentId = if (relativePath.isNullOrEmpty()) {
                DocumentsContract.getTreeDocumentId(treeUri)
            } else {
                val parentUri = buildChildUri(treeUri, relativePath)
                DocumentsContract.getDocumentId(parentUri)
            }

            val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                treeUri, parentId
            )
            val cursor: Cursor? = contentResolver.query(childUri, null, null, null, null)

            val entries = mutableListOf<Map<String, Any>>()
            cursor?.use { c ->
                val nameIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val typeIdx = c.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                while (c.moveToNext()) {
                    val name = c.getString(nameIdx)
                    if (name.startsWith(".")) continue
                    val mimeType = c.getString(typeIdx)
                    entries.add(mapOf(
                        "name" to name,
                        "isDirectory" to (mimeType == DocumentsContract.Document.MIME_TYPE_DIR)
                    ))
                }
            }
            result.success(entries)
        } catch (e: Exception) {
            result.error("LIST_ERROR", e.message, null)
        }
    }

    private fun handleReadFile(basePath: String?, relativePath: String?, result: MethodChannel.Result) {
        try {
            val treeUri = Uri.parse(basePath!!)
            val documentUri = buildChildUri(treeUri, relativePath)
            contentResolver.openInputStream(documentUri)?.use { stream ->
                result.success(stream.bufferedReader().readText())
            } ?: run {
                result.error("FILE_NOT_FOUND", "Could not open file", null)
            }
        } catch (e: Exception) {
            result.error("READ_ERROR", e.message, null)
        }
    }

    private fun handleWriteFile(basePath: String?, relativePath: String?, content: String, result: MethodChannel.Result) {
        try {
            val treeUri = Uri.parse(basePath!!)

            // Extract parent path and file name. If no "/" exists, the note lives at root.
            val hasSlash = relativePath?.contains("/") == true
            val parentPath = if (hasSlash) relativePath!!.substringBeforeLast("/") else ""
            val fileName = if (hasSlash) relativePath!!.substringAfterLast("/") else (relativePath ?: "")

            // Ensure parent directory exists (skip for root-level notes)
            if (parentPath.isNotEmpty()) {
                ensureDirectoryExists(treeUri, parentPath)
            }

            // For root notes, parent is the tree itself. For subfolder notes, resolve the folder.
            val parentId = if (parentPath.isEmpty()) {
                DocumentsContract.getTreeDocumentId(Uri.parse(basePath!!))
            } else {
                val parentUri = buildChildUri(Uri.parse(basePath!!), parentPath, mustBeDirectory = true)
                DocumentsContract.getDocumentId(parentUri)
            }

            // Check if file already exists
            val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                Uri.parse(basePath!!), parentId
            )
            var existingDocId: String? = null

            contentResolver.query(childUri, null, null, null, null)?.use { cursor ->
                val nameIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val docIdIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                while (cursor.moveToNext()) {
                    if (cursor.getString(nameIdx) == fileName) {
                        existingDocId = cursor.getString(docIdIdx)
                        break
                    }
                }
            }

            val documentUri: Uri = if (existingDocId != null) {
                DocumentsContract.buildDocumentUriUsingTree(Uri.parse(basePath!!), existingDocId!!)
            } else {
                val parentDocUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                    Uri.parse(basePath!!), parentId
                )
                DocumentsContract.createDocument(
                    contentResolver, parentDocUri, "text/markdown", fileName
                )!!
            }

            contentResolver.openOutputStream(documentUri)?.use { os ->
                os.write(content.toByteArray())
            }
            result.success(null)
        } catch (e: Exception) {
            result.error("WRITE_ERROR", e.message, null)
        }
    }

    private fun ensureDirectoryExists(treeUri: Uri, relativePath: String) {
        val parts = relativePath.split("/")
        var currentId = DocumentsContract.getTreeDocumentId(treeUri)

        for (part in parts) {
            val parentDocUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, currentId)
            var found = false

            contentResolver.query(
                DocumentsContract.buildChildDocumentsUriUsingTree(treeUri, currentId),
                null, null, null, null
            )?.use { cursor ->
                val nameIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                val docIdIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                while (cursor.moveToNext()) {
                    if (cursor.getString(nameIdx) == part) {
                        currentId = cursor.getString(docIdIdx)
                        found = true
                        break
                    }
                }
            }

            if (!found) {
                val newDocUri = DocumentsContract.createDocument(
                    contentResolver, parentDocUri,
                    DocumentsContract.Document.MIME_TYPE_DIR, part
                )!!
                currentId = DocumentsContract.getDocumentId(newDocUri)
            }
        }
    }

    private fun handleCreateDirectory(basePath: String?, relativePath: String?, result: MethodChannel.Result) {
        try {
            val treeUri = Uri.parse(basePath!!)
            ensureDirectoryExists(treeUri, relativePath!!)
            result.success(null)
        } catch (e: Exception) {
            result.error("MKDIR_ERROR", e.message, null)
        }
    }

    private fun handleDeleteEntry(basePath: String?, relativePath: String?, result: MethodChannel.Result) {
        try {
            val treeUri = Uri.parse(basePath!!)
            val documentUri = buildChildUri(treeUri, relativePath)

            // Check if it's a directory — delete children first (recursive)
            val mimeType = contentResolver.query(documentUri, null, null, null, null)?.use { cursor ->
                val typeIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                if (cursor.moveToFirst()) cursor.getString(typeIdx) else null
            }

            if (mimeType == DocumentsContract.Document.MIME_TYPE_DIR) {
                // Recursive delete: list children and delete them first
                val childUri = DocumentsContract.buildChildDocumentsUriUsingTree(
                    treeUri, DocumentsContract.getDocumentId(documentUri)
                )
                contentResolver.query(childUri, null, null, null, null)?.use { cursor ->
                    val docIdIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DOCUMENT_ID)
                    val nameIdx = cursor.getColumnIndex(DocumentsContract.Document.COLUMN_DISPLAY_NAME)
                    while (cursor.moveToNext()) {
                        val childDocId = cursor.getString(docIdIdx)
                        val childName = cursor.getString(nameIdx)
                        val childDocumentUri = DocumentsContract.buildDocumentUriUsingTree(treeUri, childDocId)

                        // Check child type and recurse if directory
                        contentResolver.query(childDocumentUri, null, null, null, null)?.use { typeCursor ->
                            val typeIdx = typeCursor.getColumnIndex(DocumentsContract.Document.COLUMN_MIME_TYPE)
                            if (typeCursor.moveToFirst()) {
                                val childType = typeCursor.getString(typeIdx)
                                if (childType == DocumentsContract.Document.MIME_TYPE_DIR) {
                                    handleDeleteEntry(
                                        basePath, "$relativePath/$childName", result
                                    )
                                } else {
                                    DocumentsContract.deleteDocument(contentResolver, childDocumentUri)
                                }
                            }
                        } ?: run {
                            DocumentsContract.deleteDocument(contentResolver, childDocumentUri)
                        }
                    }
                }
                // Now delete the empty directory
                DocumentsContract.deleteDocument(contentResolver, documentUri)
            } else {
                DocumentsContract.deleteDocument(contentResolver, documentUri)
            }

            result.success(null)
        } catch (e: Exception) {
            result.error("DELETE_ERROR", e.message, null)
        }
    }

    private fun handleRenameEntry(basePath: String?, oldRelativePath: String?, newName: String?, result: MethodChannel.Result) {
        try {
            val treeUri = Uri.parse(basePath!!)
            val documentUri = buildChildUri(treeUri, oldRelativePath)
            DocumentsContract.renameDocument(contentResolver, documentUri, newName!!)
            result.success(null)
        } catch (e: Exception) {
            result.error("RENAME_ERROR", e.message, null)
        }
    }
}
