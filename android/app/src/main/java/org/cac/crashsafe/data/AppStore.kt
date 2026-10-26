package org.cac.crashsafe.data

import android.util.Log
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import org.cac.crashsafe.model.AppData
import org.cac.crashsafe.model.CheckInRecord
import org.cac.crashsafe.model.Profile
import org.cac.crashsafe.model.Trip
import java.io.File

/**
 * The on-device store: profile, vehicles, contacts, trips and check-ins, as one JSON document in the app's
 * private files (it never leaves the phone). Screens read `data` (Compose observes it); every change goes
 * through `update`, and is written to disk shortly after. If a schema change can't be read (dev builds), the
 * store starts empty instead of crashing — it only holds this phone's demo data.
 */
class AppStore(private val file: File?, private val scope: CoroutineScope) {
    var data by mutableStateOf(load())
        private set

    private var saveJob: Job? = null

    fun update(transform: (AppData) -> AppData) {
        data = transform(data)
        scheduleSave()
    }

    // Profiles

    fun profile(ownerID: String): Profile? = data.profiles.firstOrNull { it.ownerID == ownerID }

    fun ensureProfile(ownerID: String) {
        if (profile(ownerID) == null) update { it.copy(profiles = it.profiles + Profile(ownerID = ownerID)) }
    }

    fun updateProfile(ownerID: String, transform: (Profile) -> Profile) = update { d ->
        d.copy(profiles = d.profiles.map { if (it.ownerID == ownerID) transform(it) else it })
    }

    // Trips

    fun trips(ownerID: String): List<Trip> = data.trips.filter { it.ownerID == ownerID }.sortedBy { it.startDate }

    fun trip(id: String): Trip? = data.trips.firstOrNull { it.id == id }

    fun insertTrip(trip: Trip) = update { it.copy(trips = it.trips + trip) }

    fun updateTrip(id: String, transform: (Trip) -> Trip) = update { d -> d.copy(trips = d.trips.map { if (it.id == id) transform(it) else it }) }

    fun deleteTrip(id: String) = update { d -> d.copy(trips = d.trips.filter { it.id != id }) }

    // Check-ins

    fun checkIns(ownerID: String): List<CheckInRecord> = data.checkIns.filter { it.ownerID == ownerID }.sortedByDescending { it.date }

    fun checkIn(id: String): CheckInRecord? = data.checkIns.firstOrNull { it.id == id }

    fun insertCheckIn(record: CheckInRecord) = update { it.copy(checkIns = it.checkIns + record) }

    fun updateCheckIn(id: String, transform: (CheckInRecord) -> CheckInRecord) =
        update { d -> d.copy(checkIns = d.checkIns.map { if (it.id == id) transform(it) else it }) }

    /** Delete account: everything this driver has on the phone. */
    fun deleteAll(ownerID: String) = update { d ->
        AppData(profiles = d.profiles.filter { it.ownerID != ownerID }, trips = d.trips.filter { it.ownerID != ownerID },
            checkIns = d.checkIns.filter { it.ownerID != ownerID })
    }

    // Disk

    private fun load(): AppData {
        val file = file ?: return AppData()
        if (!file.exists()) return AppData()
        return runCatching { json.decodeFromString(AppData.serializer(), file.readText()) }
            .onFailure { Log.w(TAG, "store couldn't be read; starting empty", it) }
            .getOrDefault(AppData())
    }

    private fun scheduleSave() {
        file ?: return
        saveJob?.cancel()
        saveJob = scope.launch {
            delay(250)
            write(data)
        }
    }

    /** Writes now (when the app goes to the background). */
    suspend fun flush() {
        saveJob?.cancel()
        write(data)
    }

    private suspend fun write(snapshot: AppData) = withContext(Dispatchers.IO) {
        val file = file ?: return@withContext
        runCatching {
            file.parentFile?.mkdirs()
            val temp = File(file.parentFile, file.name + ".tmp")
            temp.writeText(json.encodeToString(AppData.serializer(), snapshot))
            if (!temp.renameTo(file)) {
                file.delete()
                temp.renameTo(file)
            }
        }.onFailure { Log.w(TAG, "store couldn't be saved", it) }
    }

    private companion object {
        const val TAG = "CrashSafe.store"
        val json = Json { ignoreUnknownKeys = true; encodeDefaults = true; coerceInputValues = true }
    }
}
