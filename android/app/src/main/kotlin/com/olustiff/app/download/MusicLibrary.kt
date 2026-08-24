package com.olustiff.app.download

import android.Manifest
import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import java.io.File
import java.io.FileOutputStream
import java.io.OutputStream

/**
 * İndirilen MP3'lerin yaşadığı yer: ortak **Müzik** kitaplığındaki
 * `Music/oLusTifF` klasörü.
 *
 * Neden uygulamaya özel klasör (`Android/data/...`) DEĞİL: Android 11'den beri
 * o klasör dosya yöneticilerine kapalı, medya taramasına dahil değil ve
 * uygulama silinince içindekiler de siliniyor. Kullanıcının indirdiği şarkıyı
 * telefonundaki müzik uygulamasında bulabilmesi gerekiyor.
 *
 * İki yazma yolu var çünkü minSdk 24:
 * - Android 10+ (API 29): [MediaStore] üzerinden `RELATIVE_PATH` ile kayıt
 *   açılır; izin gerekmez, kapsamlı depolama (scoped storage) budur.
 * - Android 9 ve öncesi: klasik dosya yazma + `WRITE_EXTERNAL_STORAGE` izni.
 *   Dosya ayrıca MediaStore'a eklenir, yoksa müzik uygulamaları görmez.
 */
object MusicLibrary {

    /** Kullanıcının dosya yöneticisinde göreceği klasör adı. */
    private const val FOLDER_NAME = "oLusTifF"

    /** MediaStore'un beklediği göreli yol: "Music/oLusTifF". */
    private val relativePath = "${Environment.DIRECTORY_MUSIC}/$FOLDER_NAME"

    /** Kullanıcıya gösterilecek tam yol (hata/bilgi mesajlarında işe yarar). */
    const val DISPLAY_PATH = "Music/$FOLDER_NAME"

    /** Kitaplıktaki tek bir MP3. [uri] bir `content://` adresidir. */
    data class Entry(val uri: Uri, val name: String, val sizeBytes: Long)

    /**
     * Ortak Müzik klasörüne yazmak için çalışma anı izni gerekiyor mu.
     *
     * Android 10+ kendi eklediğimiz medyaya izinsiz yazdırır; yalnızca eski
     * sürümlerde soru sormamız gerekir.
     */
    fun needsPermission(context: Context): Boolean =
        Build.VERSION.SDK_INT < Build.VERSION_CODES.Q &&
            context.checkSelfPermission(Manifest.permission.WRITE_EXTERNAL_STORAGE) !=
            PackageManager.PERMISSION_GRANTED

    /**
     * Yeni bir MP3 kaydı açar, [write] ile doldurulmasını bekler ve kitaplığa
     * yayımlar.
     *
     * Yazma işi geri çağrıma bırakıldı çünkü kodlayıcı doğrudan MediaStore'un
     * verdiği akışa yazmalı: önce geçici bir dosyaya yazıp sonra kopyalamak
     * 100 MB'lık gereksiz disk trafiği demek.
     *
     * Aynı isim ikinci kez gelirse ÜZERİNE YAZILMAZ; MediaStore adı
     * "şarkı (1).mp3" diye çoğaltır, eski sürümlerde aynısını elle yaparız.
     * Bu yüzden gerçek dosya adı çağırana [Entry] ile geri bildirilir.
     */
    fun save(
        context: Context,
        displayName: String,
        title: String,
        artist: String?,
        write: (OutputStream) -> Unit
    ): Entry = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
        saveViaMediaStore(context, displayName, title, artist, write)
    } else {
        saveLegacy(context, displayName, title, artist, write)
    }

    @RequiresApi(Build.VERSION_CODES.Q)
    private fun saveViaMediaStore(
        context: Context,
        displayName: String,
        title: String,
        artist: String?,
        write: (OutputStream) -> Unit
    ): Entry {
        val resolver = context.contentResolver
        val values = ContentValues().apply {
            put(MediaStore.Audio.Media.DISPLAY_NAME, displayName)
            put(MediaStore.Audio.Media.MIME_TYPE, "audio/mpeg")
            // TITLE/ARTIST doldurulmazsa müzik uygulamaları dosya adını başlık,
            // sanatçıyı "<unknown>" diye gösterir.
            put(MediaStore.Audio.Media.TITLE, title)
            artist?.takeIf { it.isNotBlank() }
                ?.let { put(MediaStore.Audio.Media.ARTIST, it) }
            put(MediaStore.Audio.Media.IS_MUSIC, 1)
            put(MediaStore.Audio.Media.RELATIVE_PATH, relativePath)
            // Yazma sürerken dosya yarım; IS_PENDING onu taramadan ve diğer
            // uygulamalardan gizler, bitince açarız.
            put(MediaStore.Audio.Media.IS_PENDING, 1)
        }

        val uri = resolver.insert(collection(), values)
            ?: throw IllegalStateException("Müzik klasöründe kayıt açılamadı")

        try {
            val output = resolver.openOutputStream(uri)
                ?: throw IllegalStateException("Müzik dosyası yazmaya açılamadı")
            output.use(write)
            resolver.update(
                uri,
                ContentValues().apply { put(MediaStore.Audio.Media.IS_PENDING, 0) },
                null,
                null
            )
        } catch (e: Exception) {
            // Yarım kalan kayıt kitaplıkta çöp bırakmasın.
            runCatching { resolver.delete(uri, null, null) }
            throw e
        }

        return readEntry(context, uri) ?: Entry(uri, displayName, 0)
    }

    private fun saveLegacy(
        context: Context,
        displayName: String,
        title: String,
        artist: String?,
        write: (OutputStream) -> Unit
    ): Entry {
        if (needsPermission(context)) {
            throw SecurityException("Müzik klasörüne yazma izni verilmedi")
        }

        val dir = legacyDir()
        if (!dir.exists() && !dir.mkdirs()) {
            throw IllegalStateException("$DISPLAY_PATH klasörü oluşturulamadı")
        }

        val file = uniqueFile(dir, displayName)
        try {
            FileOutputStream(file).use(write)
        } catch (e: Exception) {
            file.delete()
            throw e
        }

        // Eski sürümlerde dosyayı yazmak yetmez; MediaStore'a eklenmezse
        // müzik uygulamaları ve dosya yöneticisi indirmeyi görmez.
        val values = ContentValues().apply {
            @Suppress("DEPRECATION")
            put(MediaStore.Audio.Media.DATA, file.absolutePath)
            put(MediaStore.Audio.Media.DISPLAY_NAME, file.name)
            put(MediaStore.Audio.Media.MIME_TYPE, "audio/mpeg")
            put(MediaStore.Audio.Media.TITLE, title)
            artist?.takeIf { it.isNotBlank() }
                ?.let { put(MediaStore.Audio.Media.ARTIST, it) }
            put(MediaStore.Audio.Media.IS_MUSIC, 1)
        }
        val resolver = context.contentResolver
        val uri = resolver.insert(collection(), values)
            ?: findByData(context, file.absolutePath)
            ?: throw IllegalStateException("Şarkı müzik kitaplığına eklenemedi")

        return Entry(uri, file.name, file.length())
    }

    /** Yalnızca `Music/oLusTifF` altındaki MP3'ler, yenisi başta. */
    fun list(context: Context): List<Entry> {
        val collection = collection()
        val projection = arrayOf(
            MediaStore.Audio.Media._ID,
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.SIZE
        )
        val selection: String
        val args: Array<String>
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            // Yarım kalmış (IS_PENDING) kayıtlar listeye girmemeli.
            selection = "${MediaStore.Audio.Media.RELATIVE_PATH} LIKE ? AND " +
                "${MediaStore.Audio.Media.IS_PENDING} = 0"
            args = arrayOf("$relativePath/%")
        } else {
            @Suppress("DEPRECATION")
            selection = "${MediaStore.Audio.Media.DATA} LIKE ?"
            args = arrayOf("%/$relativePath/%")
        }

        val items = mutableListOf<Entry>()
        context.contentResolver.query(
            collection,
            projection,
            selection,
            args,
            "${MediaStore.Audio.Media.DATE_ADDED} DESC"
        )?.use { cursor ->
            val idColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media._ID)
            val nameColumn =
                cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.DISPLAY_NAME)
            val sizeColumn = cursor.getColumnIndexOrThrow(MediaStore.Audio.Media.SIZE)
            while (cursor.moveToNext()) {
                val id = cursor.getLong(idColumn)
                items += Entry(
                    uri = ContentUris.withAppendedId(collection, id),
                    name = cursor.getString(nameColumn) ?: "",
                    sizeBytes = cursor.getLong(sizeColumn)
                )
            }
        }
        return items
    }

    /**
     * Kaydı kitaplıktan siler. Dosya artık bize ait olmayabilir (ör. uygulama
     * silinip yeniden kurulduysa), o yüzden başarısızlık istisna değil `false`.
     */
    fun delete(context: Context, uri: Uri): Boolean {
        // Eski sürümlerde MediaStore satırı silinse de dosya diskte kalabiliyor.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            legacyPathOf(context, uri)?.let { File(it).delete() }
        }
        return runCatching { context.contentResolver.delete(uri, null, null) > 0 }
            .getOrDefault(false)
    }

    /**
     * İndirme klasörünü sistemin dosya uygulamasında açar.
     *
     * Klasörü açmanın tek standart yolu yok: önce dosya yöneticisinin anladığı
     * belge adresi denenir, olmazsa "klasör türü" ile açabilen herhangi bir
     * uygulamaya düşülür. Hiçbiri yoksa kullanıcıya hata göstermek yerine
     * `false` döneriz — arayüz butonu sessizce gizleyebilsin.
     */
    fun openFolder(context: Context): Boolean {
        val documentId = "primary:$relativePath"
        val folderUri = DocumentsContract.buildDocumentUri(
            "com.android.externalstorage.documents",
            documentId
        )

        val candidates = listOf(
            Intent(Intent.ACTION_VIEW)
                .setDataAndType(folderUri, DocumentsContract.Document.MIME_TYPE_DIR),
            // Klasörü gösteremeyen cihazlarda hiç değilse dosya uygulaması açılsın.
            Intent(Intent.ACTION_VIEW).setType(DocumentsContract.Document.MIME_TYPE_DIR)
        )

        for (intent in candidates) {
            // applicationContext'ten açtığımız için yeni görev şart.
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            val started = runCatching { context.startActivity(intent) }.isSuccess
            if (started) return true
        }
        return false
    }

    /** Cihazın birincil deposundaki ses koleksiyonu. */
    private fun collection(): Uri =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            MediaStore.Audio.Media.getContentUri(MediaStore.VOLUME_EXTERNAL_PRIMARY)
        } else {
            MediaStore.Audio.Media.EXTERNAL_CONTENT_URI
        }

    @Suppress("DEPRECATION")
    private fun legacyDir(): File = File(
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_MUSIC),
        FOLDER_NAME
    )

    /** Eski sürümlerde çakışan adı MediaStore yerine biz çoğaltırız. */
    private fun uniqueFile(dir: File, displayName: String): File {
        val base = displayName.substringBeforeLast('.')
        val extension = displayName.substringAfterLast('.', "mp3")
        var candidate = File(dir, displayName)
        var index = 1
        while (candidate.exists()) {
            candidate = File(dir, "$base ($index).$extension")
            index++
        }
        return candidate
    }

    private fun readEntry(context: Context, uri: Uri): Entry? {
        val projection = arrayOf(
            MediaStore.Audio.Media.DISPLAY_NAME,
            MediaStore.Audio.Media.SIZE
        )
        context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) {
                return Entry(
                    uri = uri,
                    name = cursor.getString(0) ?: "",
                    sizeBytes = cursor.getLong(1)
                )
            }
        }
        return null
    }

    @Suppress("DEPRECATION")
    private fun findByData(context: Context, path: String): Uri? {
        val projection = arrayOf(MediaStore.Audio.Media._ID)
        context.contentResolver.query(
            collection(),
            projection,
            "${MediaStore.Audio.Media.DATA} = ?",
            arrayOf(path),
            null
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                return ContentUris.withAppendedId(collection(), cursor.getLong(0))
            }
        }
        return null
    }

    @Suppress("DEPRECATION")
    private fun legacyPathOf(context: Context, uri: Uri): String? {
        val projection = arrayOf(MediaStore.Audio.Media.DATA)
        context.contentResolver.query(uri, projection, null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) return cursor.getString(0)
        }
        return null
    }
}
