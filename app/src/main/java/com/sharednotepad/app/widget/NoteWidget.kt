package com.sharednotepad.app.widget

import android.content.Context
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.glance.GlanceId
import androidx.glance.GlanceModifier
import androidx.glance.GlanceTheme
import androidx.glance.action.ActionParameters
import androidx.glance.action.actionStartActivity
import androidx.glance.action.clickable
import androidx.glance.appwidget.GlanceAppWidget
import androidx.glance.appwidget.GlanceAppWidgetReceiver
import androidx.glance.appwidget.action.ActionCallback
import androidx.glance.appwidget.action.actionRunCallback
import androidx.glance.appwidget.appWidgetBackground
import androidx.glance.appwidget.cornerRadius
import androidx.glance.appwidget.provideContent
import androidx.glance.background
import androidx.glance.layout.Alignment
import androidx.glance.layout.Column
import androidx.glance.layout.Row
import androidx.glance.layout.Spacer
import androidx.glance.layout.defaultWeight
import androidx.glance.layout.fillMaxSize
import androidx.glance.layout.fillMaxWidth
import androidx.glance.layout.height
import androidx.glance.layout.padding
import androidx.glance.text.FontWeight
import androidx.glance.text.Text
import androidx.glance.text.TextStyle
import com.google.firebase.firestore.ktx.firestore
import com.google.firebase.ktx.Firebase
import com.sharednotepad.app.MainActivity
import com.sharednotepad.app.data.AuthHelper
import com.sharednotepad.app.data.Note
import com.sharednotepad.app.data.PadPrefs
import com.sharednotepad.app.data.displayOrder
import kotlinx.coroutines.tasks.await

class NoteWidgetReceiver : GlanceAppWidgetReceiver() {
    override val glanceAppWidget: GlanceAppWidget = NoteWidget()
}

class NoteWidget : GlanceAppWidget() {

    override suspend fun provideGlance(context: Context, id: GlanceId) {
        val paired = PadPrefs.padCode(context) != null
        val (title, content) = PadPrefs.widgetNote(context)

        provideContent {
            GlanceTheme {
                WidgetContent(
                    paired = paired,
                    title = title,
                    content = content,
                )
            }
        }
    }
}

@androidx.compose.runtime.Composable
private fun WidgetContent(paired: Boolean, title: String, content: String) {
    Column(
        modifier = GlanceModifier
            .fillMaxSize()
            .appWidgetBackground()
            .background(GlanceTheme.colors.widgetBackground)
            .cornerRadius(16.dp)
            .padding(12.dp)
            .clickable(actionStartActivity<MainActivity>()),
    ) {
        when {
            !paired -> Text(
                "Tap to set up your shared notepad",
                style = TextStyle(fontSize = 14.sp, color = GlanceTheme.colors.onSurface),
            )

            title.isBlank() && content.isBlank() -> Text(
                "No pinned note yet.\nTap to open Shared Notepad.",
                style = TextStyle(fontSize = 14.sp, color = GlanceTheme.colors.onSurface),
            )

            else -> {
                Row(
                    modifier = GlanceModifier.fillMaxWidth(),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Text(
                        title.ifBlank { "Untitled" },
                        style = TextStyle(
                            fontSize = 16.sp,
                            fontWeight = FontWeight.Bold,
                            color = GlanceTheme.colors.onSurface,
                        ),
                        maxLines = 1,
                        modifier = GlanceModifier.defaultWeight(),
                    )
                    Text(
                        "↻",
                        style = TextStyle(fontSize = 18.sp, color = GlanceTheme.colors.primary),
                        modifier = GlanceModifier
                            .padding(horizontal = 8.dp)
                            .clickable(actionRunCallback<RefreshWidgetAction>()),
                    )
                }
                Spacer(GlanceModifier.height(6.dp))
                Text(
                    content,
                    style = TextStyle(fontSize = 14.sp, color = GlanceTheme.colors.onSurface),
                    maxLines = 8,
                )
            }
        }
    }
}

/** Pulls the latest pinned note from Firestore and re-renders the widget. */
class RefreshWidgetAction : ActionCallback {
    override suspend fun onAction(
        context: Context,
        glanceId: GlanceId,
        parameters: ActionParameters,
    ) {
        runCatching {
            val padCode = PadPrefs.padCode(context) ?: return
            AuthHelper.ensureSignedIn()
            val snapshot = Firebase.firestore
                .collection("pads").document(padCode)
                .collection("notes")
                .get()
                .await()
            val notes = snapshot.toObjects(Note::class.java).displayOrder()
            val widgetNote = notes.firstOrNull { it.pinned } ?: notes.firstOrNull()
            if (widgetNote != null) {
                PadPrefs.cacheWidgetNote(context, widgetNote.title, widgetNote.content)
            }
        }
        NoteWidget().update(context, glanceId)
    }
}
