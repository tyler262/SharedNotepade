package com.sharednotepad.app

import android.app.Application
import androidx.glance.appwidget.updateAll
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.viewModelScope
import com.sharednotepad.app.data.AuthHelper
import com.sharednotepad.app.data.Note
import com.sharednotepad.app.data.NotesRepository
import com.sharednotepad.app.data.PadPrefs
import com.sharednotepad.app.widget.NoteWidget
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.flatMapLatest
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.flow.onEach
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch

sealed interface PadState {
    data object Loading : PadState
    data object NotPaired : PadState
    data class Paired(val code: String) : PadState
}

class MainViewModel(application: Application) : AndroidViewModel(application) {

    private val app = application
    private val authReady = MutableStateFlow(false)
    private val errorFlow = MutableStateFlow<String?>(null)
    val error: StateFlow<String?> = errorFlow
    val busy = MutableStateFlow(false)

    init {
        viewModelScope.launch {
            runCatching { AuthHelper.ensureSignedIn() }
                .onFailure { errorFlow.value = "Could not connect: ${it.message}" }
            authReady.value = true
        }
    }

    val padState: StateFlow<PadState> =
        combine(PadPrefs.padCodeFlow(app), authReady) { code, ready ->
            when {
                !ready -> PadState.Loading
                code == null -> PadState.NotPaired
                else -> PadState.Paired(code)
            }
        }.stateIn(viewModelScope, SharingStarted.Eagerly, PadState.Loading)

    private var repository: NotesRepository? = null

    @OptIn(ExperimentalCoroutinesApi::class)
    val notes: StateFlow<List<Note>> = padState
        .flatMapLatest { state ->
            when (state) {
                is PadState.Paired -> {
                    val repo = NotesRepository(state.code)
                    repository = repo
                    repo.notesFlow()
                }
                else -> flowOf(emptyList())
            }
        }
        .onEach { list ->
            // Keep the widget's local copy of the pinned note fresh.
            val widgetNote = list.firstOrNull { it.pinned } ?: list.firstOrNull()
            if (widgetNote != null) {
                PadPrefs.cacheWidgetNote(app, widgetNote.title, widgetNote.content)
                runCatching { NoteWidget().updateAll(app) }
            }
        }
        .catch { e ->
            errorFlow.value = "Sync error: ${e.message}"
            emit(emptyList())
        }
        .stateIn(viewModelScope, SharingStarted.Eagerly, emptyList())

    fun clearError() {
        errorFlow.value = null
    }

    fun createPad() = viewModelScope.launch {
        busy.value = true
        runCatching {
            AuthHelper.ensureSignedIn()
            val code = NotesRepository.createPad()
            PadPrefs.setPadCode(app, code)
        }.onFailure { errorFlow.value = "Could not create notepad: ${it.message}" }
        busy.value = false
    }

    fun joinPad(rawCode: String) = viewModelScope.launch {
        busy.value = true
        runCatching {
            AuthHelper.ensureSignedIn()
            val code = NotesRepository.joinPad(rawCode)
            if (code == null) {
                errorFlow.value = "No notepad found with that code. Double-check it and try again."
            } else {
                PadPrefs.setPadCode(app, code)
            }
        }.onFailure { errorFlow.value = "Could not join: ${it.message}" }
        busy.value = false
    }

    fun leavePad() = viewModelScope.launch {
        PadPrefs.setPadCode(app, null)
    }

    fun createNote(onCreated: (String) -> Unit) = viewModelScope.launch {
        runCatching { repository?.createNote("")?.let(onCreated) }
            .onFailure { errorFlow.value = "Could not create note: ${it.message}" }
    }

    suspend fun getNote(id: String): Note? =
        runCatching { repository?.getNote(id) }.getOrNull()

    fun saveNote(id: String, title: String, content: String) = viewModelScope.launch {
        runCatching { repository?.saveNote(id, title, content) }
            .onFailure { errorFlow.value = "Could not save: ${it.message}" }
    }

    fun togglePin(note: Note) = viewModelScope.launch {
        runCatching {
            if (note.pinned) repository?.unpinNote(note.id)
            else repository?.pinNote(note.id, notes.value)
        }.onFailure { errorFlow.value = "Could not pin: ${it.message}" }
    }

    fun deleteNote(id: String) = viewModelScope.launch {
        runCatching { repository?.deleteNote(id) }
            .onFailure { errorFlow.value = "Could not delete: ${it.message}" }
    }
}
