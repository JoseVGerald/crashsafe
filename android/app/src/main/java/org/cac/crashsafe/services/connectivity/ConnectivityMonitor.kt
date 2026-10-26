package org.cac.crashsafe.services.connectivity

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.Handler
import android.os.Looper
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.setValue

/**
 * Publishes whether the phone currently has a usable network path.
 * The assistant and alert services use this to pick online vs. offline behavior.
 */
class ConnectivityMonitor(context: Context?) {
    var isOnline by mutableStateOf(true)
        private set

    private val main = Handler(Looper.getMainLooper())

    init {
        val manager = context?.getSystemService(ConnectivityManager::class.java)
        if (manager != null) {
            isOnline = manager.activeNetwork?.let { manager.getNetworkCapabilities(it) }?.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) ?: false
            manager.registerDefaultNetworkCallback(object : ConnectivityManager.NetworkCallback() {
                override fun onCapabilitiesChanged(network: Network, capabilities: NetworkCapabilities) {
                    val online = capabilities.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
                    main.post { isOnline = online }
                }

                override fun onLost(network: Network) {
                    main.post { isOnline = false }
                }
            })
        }
    }
}
