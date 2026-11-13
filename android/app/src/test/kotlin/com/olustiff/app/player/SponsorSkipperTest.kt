package com.olustiff.app.player

import com.olustiff.app.player.SponsorSkipper.Segment
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class SponsorSkipperTest {
    private val sponsor = Segment(10_000, 40_000, "sponsor")
    private val outro = Segment(100_000, 120_000, "interaction")
    private val segments = listOf(sponsor, outro)

    @Test
    fun skipsWhenInsideSegment() {
        assertEquals(sponsor, SponsorSkipper.segmentToSkip(segments, 10_000, emptySet()))
        assertEquals(outro, SponsorSkipper.segmentToSkip(segments, 110_000, emptySet()))
    }

    @Test
    fun ignoresOutsideSegments() {
        assertNull(SponsorSkipper.segmentToSkip(segments, 9_999, emptySet()))
        assertNull(SponsorSkipper.segmentToSkip(segments, 50_000, emptySet()))
    }

    @Test
    fun ignoresLastHalfSecond() {
        assertNull(SponsorSkipper.segmentToSkip(segments, 39_600, emptySet()))
    }

    @Test
    fun doesNotSkipTwiceWhenUserSeeksBack() {
        assertNull(SponsorSkipper.segmentToSkip(segments, 20_000, setOf(sponsor)))
    }
}
