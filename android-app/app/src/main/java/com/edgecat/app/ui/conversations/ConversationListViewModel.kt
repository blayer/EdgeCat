package com.edgecat.app.ui.conversations

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.edgecat.app.conversations.ConversationRepository
import com.edgecat.app.conversations.db.ConversationEntity
import dagger.hilt.android.lifecycle.HiltViewModel
import javax.inject.Inject
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

@HiltViewModel
class ConversationListViewModel @Inject constructor(
  private val repository: ConversationRepository,
) : ViewModel() {

  val conversations: StateFlow<List<ConversationEntity>> =
    repository.observeConversations().stateIn(
      viewModelScope,
      SharingStarted.WhileSubscribed(5_000),
      emptyList(),
    )

  fun createConversation(onCreated: (Long) -> Unit) {
    viewModelScope.launch {
      val id = withContext(Dispatchers.IO) { repository.createConversation() }
      onCreated(id)
    }
  }

  fun deleteConversation(id: Long) {
    viewModelScope.launch(Dispatchers.IO) {
      repository.deleteConversation(id)
    }
  }

  fun setPinned(id: Long, pinned: Boolean) {
    viewModelScope.launch(Dispatchers.IO) {
      repository.setPinned(id, pinned)
    }
  }
}
