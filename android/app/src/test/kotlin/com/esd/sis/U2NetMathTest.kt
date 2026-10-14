package com.esd.sis

import org.junit.Test
import org.junit.Assert.*

class U2NetMathTest {

    private fun u(b: Byte) = b.toInt() and 0xFF

    @Test
    fun `constants are 320 and 512`() {
        assertEquals(320, U2NetMath.MODEL_SIDE)
        assertEquals(512, U2NetMath.MASK_SIDE)
    }

    @Test
    fun `input size = 3*320*320`() {
        val size = U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE
        val input = IntArray(size) { 0xFF000000.toInt() }
        val out = U2NetMath.input(input)
        assertEquals(3 * size, out.size)
    }

    @Test
    fun `input throws IllegalArgumentException for invalid sizes`() {
        val size = U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE
        val bad1 = IntArray(size - 1)
        val bad2 = IntArray(size + 1)
        val bad3 = IntArray(0)

        try {
            U2NetMath.input(bad1)
            fail("Expected IllegalArgumentException for size ${bad1.size}")
        } catch (e: IllegalArgumentException) {}

        try {
            U2NetMath.input(bad2)
            fail("Expected IllegalArgumentException for size ${bad2.size}")
        } catch (e: IllegalArgumentException) {}

        try {
            U2NetMath.input(bad3)
            fail("Expected IllegalArgumentException for size ${bad3.size}")
        } catch (e: IllegalArgumentException) {}
    }

    @Test
    fun `NHWC order`() {
        val size = U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE
        val input = IntArray(size) { 0xFF000000.toInt() }
        input[0] = 0xFFFF0000.toInt() // red
        input[1] = 0xFF00FF00.toInt() // green
        input[2] = 0xFF0000FF.toInt() // blue

        val out = U2NetMath.input(input)

        val meanR = 0.485f
        val meanG = 0.456f
        val meanB = 0.406f
        val stdR = 0.229f
        val stdG = 0.224f
        val stdB = 0.225f

        val r0 = (1f - meanR) / stdR
        val g0 = (0f - meanG) / stdG
        val b0 = (0f - meanB) / stdB

        val r1 = (0f - meanR) / stdR
        val g1 = (1f - meanG) / stdG
        val b1 = (0f - meanB) / stdB

        val r2 = (0f - meanR) / stdR
        val g2 = (0f - meanG) / stdG
        val b2 = (1f - meanB) / stdB

        assertEquals(r0, out[0], 1e-4f)
        assertEquals(g0, out[1], 1e-4f)
        assertEquals(b0, out[2], 1e-4f)

        assertEquals(r1, out[3], 1e-4f)
        assertEquals(g1, out[4], 1e-4f)
        assertEquals(b1, out[5], 1e-4f)

        assertEquals(r2, out[6], 1e-4f)
        assertEquals(g2, out[7], 1e-4f)
        assertEquals(b2, out[8], 1e-4f)
    }

    @Test
    fun `normalisation of a mid value`() {
        val size = U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE
        val input = IntArray(size) { 0xFF804020.toInt() }
        val out = U2NetMath.input(input)

        val meanR = 0.485f
        val meanG = 0.456f
        val meanB = 0.406f
        val stdR = 0.229f
        val stdG = 0.224f
        val stdB = 0.225f

        val lastIndex = size - 1
        val rLast = ((128f / 255f) - meanR) / stdR
        val gLast = ((64f / 255f) - meanG) / stdG
        val bLast = ((32f / 255f) - meanB) / stdB

        assertEquals(rLast, out[3 * lastIndex], 1e-4f)
        assertEquals(gLast, out[3 * lastIndex + 1], 1e-4f)
        assertEquals(bLast, out[3 * lastIndex + 2], 1e-4f)
    }

    @Test
    fun `alpha ignored`() {
        val size = U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE
        val arr1 = IntArray(size) { 0x00336699.toInt() }
        val arr2 = IntArray(size) { 0xFF336699.toInt() }

        val out1 = U2NetMath.input(arr1)
        val out2 = U2NetMath.input(arr2)

        assertArrayEquals(out1, out2, 0f)
    }

    @Test
    fun `mask returns null for invalid sizes`() {
        val size = U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE
        val bad1 = FloatArray(size - 1)
        // Real range, so only the size rule can reject it.
        val bad2 = FloatArray(U2NetMath.MASK_SIDE * U2NetMath.MASK_SIDE) { if (it % 2 == 0) 0f else 1f }

        assertNull(U2NetMath.mask(bad1))
        assertNull(U2NetMath.mask(bad2))
    }

    @Test
    fun `mask null for flat array and small range, non-null for valid range`() {
        val size = U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE
        val flat = FloatArray(size) { 0.5f }
        assertNull(U2NetMath.mask(flat))

        val halfHalf = FloatArray(size) { if (it < size / 2) 0.5f else 0.54f }
        assertNull(U2NetMath.mask(halfHalf))

        val valid = FloatArray(size) { if (it < size / 2) 0f else 0.2f }
        val maskOut = U2NetMath.mask(valid)
        assertNotNull(maskOut)
        assertEquals(U2NetMath.MASK_SIDE * U2NetMath.MASK_SIDE, maskOut!!.size)
    }

    @Test
    fun `mask size 512*512 for a valid input`() {
        val size = U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE
        val valid = FloatArray(size) { if (it < size / 2) 0f else 0.2f }
        val mask = U2NetMath.mask(valid)
        assertNotNull(mask)
        assertEquals(U2NetMath.MASK_SIDE * U2NetMath.MASK_SIDE, mask!!.size)
    }

    @Test
    fun `corner values`() {
        val size = U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE
        val probs = FloatArray(size) { 0.5f }
        probs[0] = 0f
        probs[319] = 1f
        probs[319 * 320] = 0.5f
        probs[319 * 320 + 319] = 0.25f

        val mask = U2NetMath.mask(probs)!!
        assertEquals(0, u(mask[0]))
        assertEquals(255, u(mask[511]))
        val bottomLeftIndex = 511 * U2NetMath.MASK_SIDE
        assertTrue(u(mask[bottomLeftIndex]) == 127 || u(mask[bottomLeftIndex]) == 128)
        val bottomRightIndex = bottomLeftIndex + 511
        assertTrue(u(mask[bottomRightIndex]) == 63 || u(mask[bottomRightIndex]) == 64)
    }

    @Test
    fun `min-max normalisation`() {
        val size = U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE
        val probs = FloatArray(size) { if (it < size / 2) 0.3f else 0.7f }
        val mask = U2NetMath.mask(probs)!!
        assertEquals(0, u(mask[0]))
        assertEquals(255, u(mask[mask.size - 1]))
    }

    @Test
    fun `bilinear midpoint`() {
        val size = U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE
        val probs = FloatArray(size) { val col = it % 320; col / 319f }
        val mask = U2NetMath.mask(probs)!!
        assertEquals(0, u(mask[0]))
        assertEquals(255, u(mask[511]))
        val midVal = u(mask[255])
        assertTrue(midVal in 126..128)
        for (i in 0 until 511) {
            assertTrue(u(mask[i]) <= u(mask[i + 1]))
        }
    }

    @Test
    fun `mask is non-null just above the 0_05 range floor`() {
        val size = U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE
        val probs = FloatArray(size) { if (it < size / 2) 0.5f else 0.56f }
        assertNotNull(U2NetMath.mask(probs))
    }

    // The "no output byte exceeds 25" rule cannot be reached through normalisation alone:
    // the align-corners step is 319/511 < 1 source pixel, so every source pixel has a sample
    // within 0.31 px on each axis (weight >= 0.47), and the max always lands above 120.
    // This test pins that a lone interior spike is still kept, not dropped by that rule.
    @Test
    fun `a lone interior spike is kept`() {
        val probs = FloatArray(U2NetMath.MODEL_SIDE * U2NetMath.MODEL_SIDE)
        probs[100 * 320 + 101] = 1f
        val mask = U2NetMath.mask(probs)
        assertNotNull(mask)
        assertTrue(mask!!.any { u(it) > 25 })
        assertEquals(0, u(mask[0]))
    }

    // Output x=4 samples source x = 4*319/511 = 2.497: halfway between columns 2 and 3.
    // A step 0 -> 1 between those columns must blend to about half, not snap to a neighbour.
    @Test
    fun `bilinear blends neighbours on both axes`() {
        val side = U2NetMath.MODEL_SIDE
        val cols = FloatArray(side * side) { if (it % side >= 3) 1f else 0f }
        assertTrue(u(U2NetMath.mask(cols)!![4]) in 125..129)
        val rows = FloatArray(side * side) { if (it / side >= 3) 1f else 0f }
        assertTrue(u(U2NetMath.mask(rows)!![4 * U2NetMath.MASK_SIDE]) in 125..129)
        // Output x=510 samples source x = 510*319/511 = 318.376 (align corners); without align
        // corners (510*320/512 = 318.75) a 0 -> 1 step between columns 318 and 319 reads ~191.
        val edge = FloatArray(side * side) { if (it % side >= 319) 1f else 0f }
        assertTrue(u(U2NetMath.mask(edge)!![510]) in 94..98)
    }
}
