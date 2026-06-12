package com.sharednotepad.app

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Surface
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.lifecycle.compose.collectAsStateWithLifecycle
import androidx.lifecycle.viewmodel.compose.viewModel
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.rememberNavController
import com.sharednotepad.app.ui.NoteEditorScreen
import com.sharednotepad.app.ui.NoteListScreen
import com.sharednotepad.app.ui.PairingScreen
import com.sharednotepad.app.ui.SharedNotepadTheme

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setContent {
            SharedNotepadTheme {
                Surface(
                    modifier = Modifier.fillMaxSize(),
                    color = MaterialTheme.colorScheme.background,
                ) {
                    SharedNotepadApp()
                }
            }
        }
    }
}

@Composable
fun SharedNotepadApp(viewModel: MainViewModel = viewModel()) {
    val padState by viewModel.padState.collectAsStateWithLifecycle()
    val busy by viewModel.busy.collectAsStateWithLifecycle()
    val error by viewModel.error.collectAsStateWithLifecycle()
    val snackbarHostState = remember { SnackbarHostState() }

    LaunchedEffect(error) {
        error?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.clearError()
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        when (val state = padState) {
            PadState.Loading -> Box(
                modifier = Modifier.fillMaxSize(),
                contentAlignment = Alignment.Center,
            ) {
                CircularProgressIndicator()
            }

            PadState.NotPaired -> PairingScreen(
                busy = busy,
                onCreatePad = viewModel::createPad,
                onJoinPad = viewModel::joinPad,
            )

            is PadState.Paired -> PairedNavHost(viewModel, state.code)
        }

        SnackbarHost(
            hostState = snackbarHostState,
            modifier = Modifier.align(Alignment.BottomCenter),
        )
    }
}

@Composable
private fun PairedNavHost(viewModel: MainViewModel, padCode: String) {
    val navController = rememberNavController()
    val notes by viewModel.notes.collectAsStateWithLifecycle()

    NavHost(navController = navController, startDestination = "list") {
        composable("list") {
            NoteListScreen(
                notes = notes,
                padCode = padCode,
                onOpenNote = { id -> navController.navigate("editor/$id") },
                onCreateNote = {
                    viewModel.createNote { id -> navController.navigate("editor/$id") }
                },
                onTogglePin = viewModel::togglePin,
                onDeleteNote = viewModel::deleteNote,
                onLeavePad = viewModel::leavePad,
            )
        }
        composable("editor/{noteId}") { backStackEntry ->
            val noteId = backStackEntry.arguments?.getString("noteId") ?: return@composable
            NoteEditorScreen(
                noteId = noteId,
                loadNote = viewModel::getNote,
                onSave = viewModel::saveNote,
                onBack = { navController.popBackStack() },
            )
        }
    }
}
