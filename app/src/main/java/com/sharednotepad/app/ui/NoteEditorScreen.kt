package com.sharednotepad.app.ui

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextField
import androidx.compose.material3.TextFieldDefaults
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.runtime.snapshotFlow
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import com.sharednotepad.app.data.Note
import kotlinx.coroutines.FlowPreview
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.debounce
import kotlinx.coroutines.flow.drop

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NoteEditorScreen(
    noteId: String,
    loadNote: suspend (String) -> Note?,
    onSave: (String, String, String) -> Unit,
    onBack: () -> Unit,
) {
    val note by produceState<Note?>(initialValue = null, noteId) {
        value = loadNote(noteId)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Edit note") },
                navigationIcon = {
                    IconButton(onClick = onBack) {
                        Icon(Icons.AutoMirrored.Filled.ArrowBack, contentDescription = "Back")
                    }
                },
            )
        },
    ) { padding ->
        val loaded = note
        if (loaded == null) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator()
            }
        } else {
            EditorContent(
                initial = loaded,
                onSave = { title, content -> onSave(noteId, title, content) },
                modifier = Modifier
                    .fillMaxSize()
                    .padding(padding)
                    .imePadding(),
            )
        }
    }
}

@OptIn(FlowPreview::class)
@Composable
private fun EditorContent(
    initial: Note,
    onSave: (String, String) -> Unit,
    modifier: Modifier = Modifier,
) {
    var title by rememberSaveable { mutableStateOf(initial.title) }
    var content by rememberSaveable { mutableStateOf(initial.content) }
    var dirty by rememberSaveable { mutableStateOf(false) }

    // Autosave: pushes to Firestore shortly after the user stops typing.
    LaunchedEffect(Unit) {
        snapshotFlow { title to content }
            .drop(1)
            .debounce(500)
            .collectLatest { (t, c) ->
                dirty = true
                onSave(t, c)
            }
    }

    // Flush keystrokes typed within the debounce window when leaving the screen.
    // Only if the note was actually edited, so an untouched note never overwrites
    // changes made on the other phone in the meantime.
    DisposableEffect(Unit) {
        onDispose {
            if (dirty || title != initial.title || content != initial.content) {
                onSave(title, content)
            }
        }
    }

    val transparentField = TextFieldDefaults.colors(
        focusedContainerColor = Color.Transparent,
        unfocusedContainerColor = Color.Transparent,
        focusedIndicatorColor = Color.Transparent,
        unfocusedIndicatorColor = Color.Transparent,
    )

    Column(modifier = modifier) {
        TextField(
            value = title,
            onValueChange = { title = it },
            placeholder = { Text("Title", style = MaterialTheme.typography.titleLarge) },
            textStyle = MaterialTheme.typography.titleLarge,
            singleLine = true,
            colors = transparentField,
            modifier = Modifier.fillMaxWidth(),
        )
        TextField(
            value = content,
            onValueChange = { content = it },
            placeholder = { Text("Start writing…") },
            colors = transparentField,
            modifier = Modifier
                .fillMaxWidth()
                .weight(1f),
        )
    }
}
