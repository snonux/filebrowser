package org.buetow.filebrowser

import android.content.ContentProvider
import android.content.ContentValues
import android.content.Context
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.provider.OpenableColumns
import java.io.File
import java.io.FileNotFoundException

/**
 * Lends a text file to an editor app (TurboNotes) for "Edit in TurboNotes".
 * The Dart side downloads it to `cache/edit/<id>/<name>`; the editor reads
 * and writes it through `content://org.buetow.filebrowser.edit/<id>/<name>`
 * with a one-off grant, and the Dart side uploads every change it sees.
 */
class EditProvider : ContentProvider() {
    companion object {
        const val AUTHORITY = "org.buetow.filebrowser.edit"

        fun editDir(context: Context): File = File(context.cacheDir, "edit")

        /** The URI of [file], which must be `cache/edit/<id>/<name>`. */
        fun uriFor(context: Context, file: File): Uri {
            val canonical = file.canonicalFile
            val id = canonical.parentFile
            if (id == null || id.parentFile != editDir(context).canonicalFile) {
                throw IllegalArgumentException("$file is not a file to edit.")
            }
            return Uri.Builder().scheme("content").authority(AUTHORITY)
                .appendPath(id.name).appendPath(canonical.name).build()
        }
    }

    override fun onCreate(): Boolean = true

    private fun file(uri: Uri): File {
        val segments = uri.pathSegments
        if (segments.size != 2 || segments.any { it.isEmpty() || it == "." || it == ".." || it.contains('/') }) {
            throw FileNotFoundException("No such file.")
        }
        val file = File(File(editDir(context!!), segments[0]), segments[1])
        if (!file.isFile) throw FileNotFoundException("No such file.")
        return file
    }

    // "wt" (write and truncate) is what editors use to save.
    override fun openFile(uri: Uri, mode: String): ParcelFileDescriptor =
        ParcelFileDescriptor.open(file(uri), ParcelFileDescriptor.parseMode(mode))

    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val file = file(uri)
        val columns = projection ?: arrayOf(OpenableColumns.DISPLAY_NAME, OpenableColumns.SIZE)
        val row = columns.map {
            when (it) {
                OpenableColumns.DISPLAY_NAME -> file.name
                OpenableColumns.SIZE -> file.length()
                else -> null
            }
        }
        return MatrixCursor(columns, 1).apply { addRow(row) }
    }

    override fun getType(uri: Uri): String = textMimeType(uri.lastPathSegment ?: "")

    override fun insert(uri: Uri, values: ContentValues?): Uri? = throw UnsupportedOperationException()

    override fun delete(uri: Uri, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException()

    override fun update(uri: Uri, values: ContentValues?, selection: String?, selectionArgs: Array<out String>?): Int =
        throw UnsupportedOperationException()
}

/** Markdown gets its own type so Markdown editors can claim it. */
internal fun textMimeType(name: String): String =
    when (name.substringAfterLast('.', "").lowercase()) {
        "md", "markdown" -> "text/markdown"
        else -> "text/plain"
    }
