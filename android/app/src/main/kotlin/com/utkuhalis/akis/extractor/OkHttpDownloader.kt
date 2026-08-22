package com.utkuhalis.akis.extractor

import okhttp3.OkHttpClient
import okhttp3.Request as OkRequest
import okhttp3.RequestBody
import okhttp3.RequestBody.Companion.toRequestBody
import org.schabi.newpipe.extractor.downloader.Downloader
import org.schabi.newpipe.extractor.downloader.Request
import org.schabi.newpipe.extractor.downloader.Response
import org.schabi.newpipe.extractor.exceptions.ReCaptchaException
import java.io.IOException
import java.util.concurrent.TimeUnit

/**
 * NewPipeExtractor'ın ihtiyaç duyduğu tek HTTP giriş noktası.
 * NewPipe uygulamasının kendisi de aynı şekilde OkHttp üzerinden bir
 * [Downloader] implementasyonu sağlar.
 */
class OkHttpDownloader private constructor(builder: OkHttpClient.Builder) : Downloader() {

    private val client: OkHttpClient = builder
        .readTimeout(30, TimeUnit.SECONDS)
        .connectTimeout(15, TimeUnit.SECONDS)
        .build()

    companion object {
        @Volatile
        private var instance: OkHttpDownloader? = null

        fun getInstance(): OkHttpDownloader =
            instance ?: synchronized(this) {
                instance ?: OkHttpDownloader(OkHttpClient.Builder()).also { instance = it }
            }
    }

    @Throws(IOException::class, ReCaptchaException::class)
    override fun execute(request: Request): Response {
        val httpMethod = request.httpMethod()
        val url = request.url()
        val headers = request.headers()
        val dataToSend = request.dataToSend()

        var requestBody: RequestBody? = null
        if (dataToSend != null) {
            requestBody = dataToSend.toRequestBody()
        }

        val requestBuilder = OkRequest.Builder()
            .method(httpMethod, requestBody)
            .url(url)
            // NewPipeExtractor'ın gördüğü tarayıcı gibi görünmesi için User-Agent şart.
            .header(
                "User-Agent",
                "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 " +
                    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
            )

        for ((headerName, headerValueList) in headers) {
            if (headerValueList.size > 1) {
                requestBuilder.removeHeader(headerName)
                for (value in headerValueList) {
                    requestBuilder.addHeader(headerName, value)
                }
            } else if (headerValueList.size == 1) {
                requestBuilder.header(headerName, headerValueList[0])
            }
        }

        val response = client.newCall(requestBuilder.build()).execute()

        if (response.code == 429) {
            response.close()
            throw ReCaptchaException("reCaptcha çözülmesi gerekiyor", url)
        }

        val body = response.body
        val responseBodyToReturn = body?.string() ?: ""
        val latestUrl = response.request.url.toString()

        return Response(
            response.code,
            response.message,
            response.headers.toMultimap(),
            responseBodyToReturn,
            latestUrl
        )
    }
}
