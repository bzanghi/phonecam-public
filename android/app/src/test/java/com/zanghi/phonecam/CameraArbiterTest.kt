package com.zanghi.phonecam

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class CameraArbiterTest {
    @Test fun firstRequestOwns() {
        val a = CameraArbiter()
        assertTrue(a.request("home"))
        assertFalse(a.request("work"))
        assertEquals("home", a.owner)
        assertTrue(a.isWaiting("work"))
    }

    @Test fun repeatedRequestFromOwnerStaysOwner() {
        val a = CameraArbiter()
        a.request("home")
        assertTrue(a.request("home"))
        assertEquals(emptyList<String>(), a.queue)
    }

    @Test fun releasePassesToLongestWaiting() {
        val a = CameraArbiter()
        a.request("home"); a.request("work"); a.request("lab")
        assertEquals("work", a.release("home"))
        assertEquals(listOf("lab"), a.queue)
        assertEquals("lab", a.release("work"))
        assertNull(a.release("lab"))
        assertNull(a.owner)
    }

    @Test fun releaseByWaiterDoesNotChangeOwner() {
        val a = CameraArbiter()
        a.request("home"); a.request("work")
        assertNull(a.release("work"))
        assertEquals("home", a.owner)
        assertNull(a.release("home"))
        assertNull(a.owner)
    }

    @Test fun takeOverQueuesPreviousOwnerFirst() {
        val a = CameraArbiter()
        a.request("home"); a.request("work"); a.request("lab")
        assertTrue(a.takeOver("lab"))
        assertEquals("lab", a.owner)
        assertEquals(listOf("home", "work"), a.queue)
        assertFalse(a.takeOver("nobody"))
    }
}

class CameraArbiterHandoverTest {
    @Test fun takeOverByOwnerOrUnknownChangesNothing() {
        val a = CameraArbiter()
        a.request("home"); a.request("work")
        assertFalse(a.takeOver("home"))
        assertEquals("home", a.owner)
        assertEquals(listOf("work"), a.queue)
        assertFalse(a.takeOver("nobody"))
        assertEquals("home", a.owner)
        assertEquals(listOf("work"), a.queue)
    }

    @Test fun previousOwnerGetsCameraBackWhenTakerIsDone() {
        // "Use on this Mac" on work while home has it: home waits, then gets it back when work goes idle.
        val a = CameraArbiter()
        a.request("home"); a.request("work")
        assertTrue(a.takeOver("work"))
        assertTrue(a.isWaiting("home"))
        assertEquals("home", a.release("work"))
        assertEquals(emptyList<String>(), a.queue)
    }

    @Test fun previousOwnerThatStopsWaitingIsSkipped() {
        val a = CameraArbiter()
        a.request("home"); a.request("work"); a.request("lab")
        a.takeOver("lab")                 // queue: home, work
        assertNull(a.release("home"))     // home's app closed while waiting
        assertEquals("work", a.release("lab"))
    }

    @Test fun waiterRequestingAgainKeepsItsPlace() {
        val a = CameraArbiter()
        a.request("home"); a.request("work"); a.request("lab")
        assertFalse(a.request("work"))
        assertEquals(listOf("work", "lab"), a.queue)
    }

    @Test fun clearDropsOwnerAndQueue() {
        val a = CameraArbiter()
        a.request("home"); a.request("work")
        a.clear()
        assertNull(a.owner)
        assertEquals(emptyList<String>(), a.queue)
        assertTrue(a.request("work"))
    }
}
