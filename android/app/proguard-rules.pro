# NewPipeExtractor, YouTube'un imza çözümlemesini Rhino (org.mozilla.javascript)
# üzerinde JavaScript çalıştırarak yapar. Rhino, Android'de bulunmayan bazı
# Java SE sınıflarına isteğe bağlı olarak referans verir; bunlar çalışma anında
# kullanılmadığı için uyarıları susturuyoruz.
-dontwarn java.beans.**
-dontwarn javax.script.**
# Rhino'nun JDK'ya özel "dynalink" optimize edici yolu; Android'de bu sınıflar
# yoktur ve Rhino çalışma anında yorumlayıcı moda düşer.
-dontwarn jdk.dynalink.**

# Rhino sınıf ve üyelerini reflection ile bulur; karıştırılırsa imza
# çözümlemesi çalışma anında bozulur ve videolar oynatılamaz.
-keep class org.mozilla.javascript.** { *; }

# NewPipeExtractor de reflection kullanır (servis/extractor keşfi).
-keep class org.schabi.newpipe.extractor.** { *; }
-dontwarn org.schabi.newpipe.extractor.**

# Uygulamanın kendi native köprü sınıfları Flutter tarafından adla çağrılır.
-keep class com.utkuhalis.akis.** { *; }
