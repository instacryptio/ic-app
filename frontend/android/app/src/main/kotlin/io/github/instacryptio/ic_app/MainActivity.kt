package io.github.instacryptio.ic_app

import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.DocumentsContract
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.io.IOException

class MainActivity : FlutterActivity() {
    companion object {
        init {
            System.loadLibrary("backend")
        }

        // Flugo's native file-chooser channel. Handles the Storage Access
        // Framework "save" and "reveal folder" flows that need the real
        // content:// URI (file_picker discards it, returning a fake path).
        private const val CHANNEL = "flugo/filechooser"
        private const val REQ_SAVE_DOCUMENT = 0xF1C0
        private const val REQ_OPEN_FOLDER = 0xF1C1
    }

    private var pendingSaveResult: MethodChannel.Result? = null
    private var pendingSaveSourcePath: String? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "saveDocument" -> saveDocument(
                        call.argument<String>("fileName") ?: "file",
                        call.argument<String>("mimeType") ?: "*/*",
                        call.argument<String>("sourcePath") ?: "",
                        result,
                    )
                    "openFolder" -> openFolder(call.argument<String>("uri") ?: "", result)
                    else -> result.notImplemented()
                }
            }
    }

    // saveDocument runs the SAF create-document dialog, then streams the bytes at
    // sourcePath into the chosen destination and returns its content:// URI (or
    // null if the user cancelled). Unlike file_picker this surfaces the REAL URI,
    // so the folder can later be revealed at its true location.
    private fun saveDocument(
        fileName: String,
        mimeType: String,
        sourcePath: String,
        result: MethodChannel.Result,
    ) {
        if (sourcePath.isEmpty()) {
            result.error("bad_args", "sourcePath is required", null)
            return
        }
        if (pendingSaveResult != null) {
            result.error("busy", "another save is already in progress", null)
            return
        }
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        pendingSaveResult = result
        pendingSaveSourcePath = sourcePath
        try {
            startActivityForResult(intent, REQ_SAVE_DOCUMENT)
        } catch (e: ActivityNotFoundException) {
            pendingSaveResult = null
            pendingSaveSourcePath = null
            result.error("no_saf", "no document provider available", e.message)
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == REQ_SAVE_DOCUMENT) {
            val result = pendingSaveResult
            val src = pendingSaveSourcePath
            pendingSaveResult = null
            pendingSaveSourcePath = null
            val uri = data?.data
            if (resultCode != Activity.RESULT_OK || uri == null || src == null) {
                result?.success(null) // cancelled — no destination chosen
                return
            }
            // Copy off the UI thread: shared files can be large.
            Thread {
                try {
                    contentResolver.openOutputStream(uri)?.use { out ->
                        File(src).inputStream().use { it.copyTo(out) }
                    } ?: throw IOException("could not open output stream for $uri")
                    try {
                        contentResolver.takePersistableUriPermission(
                            uri,
                            Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                        )
                    } catch (_: Exception) {
                        // Not all providers grant persistable permission; harmless.
                    }
                    runOnUiThread { result?.success(uri.toString()) }
                } catch (e: Exception) {
                    runOnUiThread { result?.error("save_failed", e.message, null) }
                }
            }.start()
            return
        }
        if (requestCode == REQ_OPEN_FOLDER) {
            // The reveal picker is also our "tap to open" surface: ACTION_OPEN_DOCUMENT
            // returns the tapped file's URI instead of opening it, so we forward the
            // selection to ACTION_VIEW ourselves. Cancel (back) does nothing.
            val picked = data?.data
            if (resultCode == Activity.RESULT_OK && picked != null) {
                openPickedDocument(picked)
            }
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    // openFolder reveals the folder containing a saved document by launching the
    // SAF picker positioned at the document's PARENT via EXTRA_INITIAL_URI — the
    // accepted Android workaround, since there is no reliable intent to browse an
    // arbitrary folder. Launched for-result so a tapped file is opened (see
    // onActivityResult). Returns false when no provider can handle it.
    private fun openFolder(uriStr: String, result: MethodChannel.Result) {
        if (uriStr.isEmpty()) {
            result.success(false)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "*/*"
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            parentDocumentUri(Uri.parse(uriStr))?.let {
                intent.putExtra(DocumentsContract.EXTRA_INITIAL_URI, it)
            }
        }
        try {
            startActivityForResult(intent, REQ_OPEN_FOLDER)
            result.success(true)
        } catch (e: ActivityNotFoundException) {
            result.success(false)
        }
    }

    // openPickedDocument opens a document the user tapped in the reveal picker with
    // its default app (ACTION_VIEW), granting the target read access to the URI.
    private fun openPickedDocument(uri: Uri) {
        val mime = contentResolver.getType(uri) ?: "*/*"
        val view = Intent(Intent.ACTION_VIEW).apply {
            setDataAndType(uri, mime)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        try {
            startActivity(view)
        } catch (e: ActivityNotFoundException) {
            // No installed app can open this type; nothing to do.
        }
    }

    // parentDocumentUri turns a document URI (…/document/primary:Foo/bar.txt)
    // into its parent folder's document URI (…/document/primary:Foo), suitable
    // for EXTRA_INITIAL_URI. Returns null if the URI isn't a document URI.
    private fun parentDocumentUri(docUri: Uri): Uri? {
        return try {
            val docId = DocumentsContract.getDocumentId(docUri)
            val slash = docId.lastIndexOf('/')
            val parentId = when {
                slash > 0 -> docId.substring(0, slash)
                docId.contains(':') -> docId.substringBefore(':') + ":"
                else -> docId
            }
            DocumentsContract.buildDocumentUri(docUri.authority, parentId)
        } catch (e: Exception) {
            null
        }
    }
}
