package com.zanghi.phonecam

import org.json.JSONObject
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class MacListTest {
    private fun mac(id: String, name: String = id, hosts: List<String> = listOf("192.168.1.10"), secret: String = "s-$id") =
        MacList.entry(id, name, hosts, 47800, secret)

    private fun ids(list: List<JSONObject>) = list.map { it.optString("macId") }

    @Test fun pairingSeveralMacsKeepsThemAllOldestFirst() {
        var list = emptyList<JSONObject>()
        list = MacList.upsert(list, mac("home"))
        list = MacList.upsert(list, mac("work"))
        list = MacList.upsert(list, mac("lab"))
        assertEquals(listOf("home", "work", "lab"), ids(list))
    }

    @Test fun rePairingReplacesInPlaceWithTheNewSecret() {
        var list = listOf(mac("home"), mac("work"))
        list = MacList.upsert(list, mac("home", name = "Home Studio", secret = "renewed"))
        assertEquals(listOf("home", "work"), ids(list))
        assertEquals("renewed", list[0].optString("secret"))
        assertEquals("Home Studio", list[0].optString("name"))
        assertEquals("s-work", list[1].optString("secret"))
    }

    @Test fun forgettingOneMacKeepsTheOthers() {
        val list = MacList.remove(listOf(mac("home"), mac("work"), mac("lab")), "work")
        assertEquals(listOf("home", "lab"), ids(list))
        assertEquals(ids(list), ids(MacList.remove(list, "unknown")))
    }

    @Test fun addressUpdateTouchesOnlyThatMacNewestFirstCapped() {
        var list = listOf(mac("home", hosts = listOf("192.168.1.10", "10.0.0.5")), mac("work", hosts = listOf("172.16.0.2")))
        list = MacList.updateAddress(list, "home", "10.0.0.5", 47801)
        assertEquals("10.0.0.5,192.168.1.10", list[0].optString("hosts"))
        assertEquals(47801, list[0].optInt("port"))
        assertEquals("172.16.0.2", list[1].optString("hosts"))
        assertEquals(47800, list[1].optInt("port"))
        for (h in listOf("10.0.0.6", "10.0.0.7", "10.0.0.8", "10.0.0.9")) list = MacList.updateAddress(list, "home", h, 47800)
        assertEquals("10.0.0.9,10.0.0.8,10.0.0.7,10.0.0.6", list[0].optString("hosts"))
    }

    @Test fun legacySingleMacMovesIntoTheList() {
        val list = MacList.migrateLegacy("old", "Office", "192.168.1.4", 47800, "wrapped", hasList = false)!!
        assertEquals(listOf("old"), ids(list))
        assertEquals("Office", list[0].optString("name"))
        assertEquals("wrapped", list[0].optString("secret"))
    }

    @Test fun legacyEntryIgnoredWithoutSecretOrWhenListExists() {
        assertNull(MacList.migrateLegacy("old", "Office", "", 47800, null, hasList = false))
        assertNull(MacList.migrateLegacy("old", "Office", "", 47800, "wrapped", hasList = true))
        assertEquals("Mac", MacList.migrateLegacy("old", null, null, 47800, "w", hasList = false)!![0].optString("name"))
    }
}
