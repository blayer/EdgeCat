/*
 * Copyright 2025 Google LLC
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

package com.edgecat.app.di

import android.content.Context
import androidx.datastore.core.DataStore
import androidx.datastore.core.DataStoreFactory
import androidx.datastore.core.Serializer
import androidx.datastore.dataStoreFile
import androidx.room.Room
import com.edgecat.app.AppLifecycleProvider
import com.edgecat.app.BenchmarkResultsSerializer
import com.edgecat.app.CutoutsSerializer
import com.edgecat.app.EdgeCatLifecycleProvider
import com.edgecat.app.SettingsSerializer
import com.edgecat.app.SkillsSerializer
import com.edgecat.app.UserDataSerializer
import com.edgecat.app.data.DataStoreRepository
import com.edgecat.app.data.DefaultDataStoreRepository
import com.edgecat.app.data.DefaultDownloadRepository
import com.edgecat.app.data.DownloadRepository
import com.edgecat.app.conversations.ConversationRepository
import com.edgecat.app.conversations.DefaultConversationRepository
import com.edgecat.app.conversations.db.ConversationDao
import com.edgecat.app.data.db.AppDatabase
import com.edgecat.app.memory.DefaultMemoryRepository
import com.edgecat.app.memory.MemoryRepository
import com.edgecat.app.memory.db.MemoryDao
import com.edgecat.app.proto.BenchmarkResults
import com.edgecat.app.proto.CutoutCollection
import com.edgecat.app.proto.Settings
import com.edgecat.app.proto.Skills
import com.edgecat.app.proto.UserData
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
internal object AppModule {

  // Provides the SettingsSerializer
  @Provides
  @Singleton
  fun provideSettingsSerializer(): Serializer<Settings> {
    return SettingsSerializer
  }

  // Provides the CutoutSerializer
  @Provides
  @Singleton
  fun provideCutoutSerializer(): Serializer<CutoutCollection> {
    return CutoutsSerializer
  }

  // Provides the UserDataSerializer
  @Provides
  @Singleton
  fun provideUserDataSerializer(): Serializer<UserData> {
    return UserDataSerializer
  }

  // Provides the BenchmarkResultsSerializer
  @Provides
  @Singleton
  fun provideBenchmarkResultsSerializer(): Serializer<BenchmarkResults> {
    return BenchmarkResultsSerializer
  }

  // Provides the SkillsSerializer
  @Provides
  @Singleton
  fun provideSkillsSerializer(): Serializer<Skills> {
    return SkillsSerializer
  }

  // Provides DataStore<Settings>
  @Provides
  @Singleton
  fun provideSettingsDataStore(
    @ApplicationContext context: Context,
    settingsSerializer: Serializer<Settings>,
  ): DataStore<Settings> {
    return DataStoreFactory.create(
      serializer = settingsSerializer,
      produceFile = { context.dataStoreFile("settings.pb") },
    )
  }

  // Provides DataStore<CutoutCollection>
  @Provides
  @Singleton
  fun provideCutoutsDataStore(
    @ApplicationContext context: Context,
    cutoutsSerializer: Serializer<CutoutCollection>,
  ): DataStore<CutoutCollection> {
    return DataStoreFactory.create(
      serializer = cutoutsSerializer,
      produceFile = { context.dataStoreFile("cutouts.pb") },
    )
  }

  // Provides DataStore<UserData>
  @Provides
  @Singleton
  fun provideUserDataDataStore(
    @ApplicationContext context: Context,
    userDataSerializer: Serializer<UserData>,
  ): DataStore<UserData> {
    return DataStoreFactory.create(
      serializer = userDataSerializer,
      produceFile = { context.dataStoreFile("user_data.pb") },
    )
  }

  // Provides DataStore<BenchmarkResults>
  @Provides
  @Singleton
  fun provideBenchmarkResultsDataStore(
    @ApplicationContext context: Context,
    benchmarkResultsSerializer: Serializer<BenchmarkResults>,
  ): DataStore<BenchmarkResults> {
    return DataStoreFactory.create(
      serializer = benchmarkResultsSerializer,
      produceFile = { context.dataStoreFile("benchmark_results.pb") },
    )
  }

  // Provides DataStore<Skills>
  @Provides
  @Singleton
  fun provideSkillsDataStore(
    @ApplicationContext context: Context,
    skillsSerializer: Serializer<Skills>,
  ): DataStore<Skills> {
    return DataStoreFactory.create(
      serializer = skillsSerializer,
      produceFile = { context.dataStoreFile("skills.pb") },
    )
  }

  // Provides AppLifecycleProvider
  @Provides
  @Singleton
  fun provideAppLifecycleProvider(): AppLifecycleProvider {
    return EdgeCatLifecycleProvider()
  }

  // Provides DataStoreRepository
  @Provides
  @Singleton
  fun provideDataStoreRepository(
    dataStore: DataStore<Settings>,
    userDataDataStore: DataStore<UserData>,
    cutoutsDataStore: DataStore<CutoutCollection>,
    benchmarkResultsStore: DataStore<BenchmarkResults>,
    skillsDataStore: DataStore<Skills>,
  ): DataStoreRepository {
    return DefaultDataStoreRepository(
      dataStore,
      userDataDataStore,
      cutoutsDataStore,
      benchmarkResultsStore,
      skillsDataStore,
    )
  }

  // Provides DownloadRepository
  @Provides
  @Singleton
  fun provideDownloadRepository(
    @ApplicationContext context: Context,
    lifecycleProvider: AppLifecycleProvider,
  ): DownloadRepository {
    return DefaultDownloadRepository(context, lifecycleProvider)
  }

  // Provides AppDatabase (shared Room DB for memory + conversations).
  @Provides
  @Singleton
  fun provideAppDatabase(
    @ApplicationContext context: Context,
  ): AppDatabase {
    return Room.databaseBuilder(
      context,
      AppDatabase::class.java,
      "edgecat.db",
    ).fallbackToDestructiveMigration().build()
  }

  // Provides MemoryDao
  @Provides
  @Singleton
  fun provideMemoryDao(database: AppDatabase): MemoryDao {
    return database.memoryDao()
  }

  // Provides MemoryRepository
  @Provides
  @Singleton
  fun provideMemoryRepository(dao: MemoryDao): MemoryRepository {
    return DefaultMemoryRepository(dao)
  }

  // Provides ConversationDao
  @Provides
  @Singleton
  fun provideConversationDao(database: AppDatabase): ConversationDao {
    return database.conversationDao()
  }

  // Provides ConversationRepository
  @Provides
  @Singleton
  fun provideConversationRepository(dao: ConversationDao): ConversationRepository {
    return DefaultConversationRepository(dao)
  }
}
