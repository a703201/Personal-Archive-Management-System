package cangjie_tpc::opengauss.proto3

import std.unittest.*
import std.unittest.testmacro.*
import std.io.*



@Test
public class TestBackend {
    @TestCase
    func testBind(): Unit {
        try
        {
            let req = Bind()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testClose(): Unit {
        try
        {
            let req = Close()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testDescribe(): Unit {
        try
        {
            let req = Describe()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testExecute(): Unit {
        try
        {
            let req = Execute()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testFunctionCall(): Unit {
        try
        {
            var req = FunctionCall()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testCopyFail(): Unit {
        try
        {
            let req = CopyFail()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testCopyData(): Unit {
        try
        {
            let req = CopyData()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testCopyDone(): Unit {
        try
        {
            let req = CopyDone()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testFlush(): Unit {
        try
        {
            let req = Flush()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testParse(): Unit {
        try
        {
            let req = Parse()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testSASLInitialResponse(): Unit {
        try
        {
            let req = SASLInitialResponse()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testPasswordMessage(): Unit {
        try
        {
            let req = PasswordMessage()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testQuery(): Unit {
        try
        {
            let req = Query()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testSync(): Unit {
        try
        {
            let req = Sync()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }

    @TestCase
    func testTerminate(): Unit {
        try
        {
            let req = Terminate()
            let input = ByteBuffer(req.encode())
            let input_stream = BufferedInputStream(input)
            let output = ByteBuffer()
            let output_stream = BufferedOutputStream(output)

            let backend = Backend(input_stream, output_stream)
            backend.receive().getOrThrow()
        } catch (ex: Exception) {
            @Assert(false)
        }
    }
}
