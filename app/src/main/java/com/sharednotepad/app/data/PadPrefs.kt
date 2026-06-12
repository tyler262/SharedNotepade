package com.sharednotepad.app.data

import android.content.Context
import androidx.datastore.preferences.core.edit
import androidx.datastore.preferences.core.stringPreferencesKey
import androidx.datastore.preferences.preferencesDataStore
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.map

private val Context.dataStore by preferencesDataStore(name = "pad_prefs")

/**
 * Small on-device store for the pad share code and a cached copy of the
 * pinned note so the home-screen widget can render without a network call.
 */
object PadPrefs {
    private val PAD_CODE = stringPreferencesKey("pad_code")
    private val WIDGET_TITLE = stringPreferencesKey("widget_title")
    private val WIDGET_CONTENT = stringPreferencesKey("widget_content")

    fun padCodeFlow(context: Context): Flow<String?> =
        context.dataStore.data.map { it[PAD_CODE] }

    suspend fun padCode(context: Context): String? =
        padCodeFlow(context).first()

    suspend fun setPadCode(context: Context, code: String?) {
        context.dataStore.edit { prefs ->
            if (code == null) prefs.remove(PAD_CODE) else prefs[PAD_CODE] = code
        }
    }

    suspend fun cacheWidgetNote(context: Context, title: String, content: String) {
        context.dataStore.edit { prefs ->
            prefs[WIDGET_TITLE] = title
            prefs[WIDGET_CONTENT] = content
        }
    }

    suspend fun widgetNote(context: Context): Pair<String, String> {
        val prefs = context.dataStore.data.first()
        return (prefs[WIDGET_TITLE] ?: "") to (prefs[WIDGET_CONTENT] ?: "")
    }
}
