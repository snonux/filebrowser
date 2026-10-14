package org.buetow.filebrowser

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.OpenableColumns
import android.webkit.MimeTypeMap
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Receives files and text that other apps share with File Browser.
 *
 * Shared files are copied into the app's cache while the sending app's read
 * grant is still valid, so the upload can take as long as it needs. The
 * Flutter side asks for the share with `take`; `received` tells it that one
 * is waiting.
 *
 * It also lends text files to TurboNotes for "Edit in TurboNotes" (the
 * `org.buetow.filebrowser/edit` channel, files served by [EditProvider]).
 */
class MainActivity : FlutterActivity() {
    private var channel: MethodChannel? = null
    private var pending: Map<String, Any?>? = null
    private val main = Handler(Looper.getMainLooper())

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // A recreated activity has already handled its intent.
        if (savedInstanceState == null) receive(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        receive(intent)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL).apply {
            setMethodCallHandler { call, result ->
                when (call.method) {
                    "take" -> {
                        result.success(pending)
                        pending = null
                    }
                    else -> result.notImplemented()
                }
            }
        }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, EDIT_CHANNEL)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "editorName" -> result.success(if (hasTurboNotes()) "TurboNotes" else null)
                    "edit" -> {
                        val path = call.argument<String>("path")
                        if (path == null) {
                            result.error("bad_args", "path is required.", null)
                        } else {
                            result.success(edit(File(path)))
                        }
                    }
                    else -> result.notImplemented()
                }
            }
    }

    private fun editIntent(file: File): Intent {
        val uri = EditProvider.uriFor(this, file)
        return Intent(Intent.ACTION_EDIT).apply {
            setDataAndType(uri, textMimeType(file.name))
            clipData = ClipData.newRawUri(file.name, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
        }
    }

    private fun hasTurboNotes(): Boolean = try {
        packageManager.getPackageInfo(TURBONOTES, 0)
        true
    } catch (e: PackageManager.NameNotFoundException) {
        false
    }

    /** Hands [file] to TurboNotes, or else to an editor the user picks.
     *  Returns an error message, or null. */
    private fun edit(file: File): String? = try {
        val intent = editIntent(file)
        if (hasTurboNotes()) {
            intent.setPackage(TURBONOTES)
            try {
                startActivity(intent)
            } catch (e: ActivityNotFoundException) {
                // An old TurboNotes that cannot edit other apps' files yet.
                intent.setPackage(null)
                startActivity(Intent.createChooser(intent, null))
            }
        } else {
            startActivity(Intent.createChooser(intent, null))
        }
        null
    } catch (e: ActivityNotFoundException) {
        "No app can edit text files. Install TurboNotes from F-Droid."
    } catch (e: IllegalArgumentException) {
        e.message ?: e.toString()
    }

    private fun receive(intent: Intent?) {
        val action = intent?.action
        if (action != Intent.ACTION_SEND && action != Intent.ACTION_SEND_MULTIPLE) return
        val uris = streams(intent)
        val text = intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()
        val subject = intent.getStringExtra(Intent.EXTRA_SUBJECT)
        if (uris.isEmpty() && text.isNullOrEmpty()) return
        Thread {
            val share = try {
                copy(uris, text, subject)
            } catch (e: Exception) {
                mapOf("error" to (e.message ?: e.toString()))
            }
            main.post {
                pending = share
                channel?.invokeMethod("received", null)
            }
        }.start()
    }

    @Suppress("DEPRECATION")
    private fun streams(intent: Intent): List<Uri> {
        if (intent.action == Intent.ACTION_SEND_MULTIPLE) {
            val list = if (Build.VERSION.SDK_INT >= 33) {
                intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
            } else {
                intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
            }
            return list?.filterNotNull() ?: emptyList()
        }
        val uri = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
        } else {
            intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
        }
        return listOfNotNull(uri)
    }

    /** Copies [uris] into a fresh cache folder; text travels as is. */
    private fun copy(uris: List<Uri>, text: String?, subject: String?): Map<String, Any?> {
        val root = File(cacheDir, "shared")
        cleanUp(root)
        val dir = File(root, System.currentTimeMillis().toString())
        dir.mkdirs()
        val files = mutableListOf<String>()
        val used = mutableSetOf<String>()
        for (uri in uris) {
            val target = unique(dir, displayName(uri), used)
            contentResolver.openInputStream(uri)?.use { input ->
                target.outputStream().use { input.copyTo(it) }
            } ?: continue
            files.add(target.absolutePath)
        }
        return mapOf(
            "dir" to dir.absolutePath,
            "files" to files,
            // With files, the text is usually a caption or the same link.
            "text" to (if (files.isEmpty()) text else null),
            "subject" to subject,
        )
    }

    /** Removes shares left behind more than a day ago. */
    private fun cleanUp(root: File) {
        val old = System.currentTimeMillis() - 24 * 60 * 60 * 1000L
        root.listFiles()?.filter { it.lastModified() < old }?.forEach { it.deleteRecursively() }
    }

    private fun displayName(uri: Uri): String {
        var name: String? = null
        if (uri.scheme == "content") {
            contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                ?.use { if (it.moveToFirst() && !it.isNull(0)) name = it.getString(0) }
        }
        if (name.isNullOrBlank()) name = uri.lastPathSegment?.substringAfterLast('/')
        var result = name?.replace('/', '_')?.trim().orEmpty()
        if (result.isEmpty() || result == "." || result == "..") result = "shared"
        if (!result.contains('.')) {
            val ext = MimeTypeMap.getSingleton()
                .getExtensionFromMimeType(contentResolver.getType(uri) ?: "")
            if (!ext.isNullOrEmpty()) result = "$result.$ext"
        }
        return result
    }

    private fun unique(dir: File, name: String, used: MutableSet<String>): File {
        val dot = name.lastIndexOf('.')
        val stem = if (dot > 0) name.substring(0, dot) else name
        val ext = if (dot > 0) name.substring(dot) else ""
        var candidate = name
        var i = 1
        while (!used.add(candidate)) candidate = "$stem (${i++})$ext"
        return File(dir, candidate)
    }

    companion object {
        private const val CHANNEL = "org.buetow.filebrowser/share"
        private const val EDIT_CHANNEL = "org.buetow.filebrowser/edit"

        /** Text files open in TurboNotes when it is installed. */
        private const val TURBONOTES = "org.buetow.turbonotes"
    }
}
