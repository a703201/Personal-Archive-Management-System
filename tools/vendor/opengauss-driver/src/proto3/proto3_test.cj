package cangjie_tpc::opengauss.proto3


import std.unittest.*
import std.unittest.testmacro.*
import cangjie_tpc::opengauss.utils.*

@Test
public class TestAllProtos {
    @TestCase
    func testAuthenticationCleartextPassword(): Unit {
        let proto = AuthenticationCleartextPassword()        
        proto.toString()

        let deserialize_proto = AuthenticationCleartextPassword.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.code.value() == proto.code.value())

        var decode_proto = AuthenticationCleartextPassword()
        decode_proto.decode(proto.encode())
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.code.value() == proto.code.value())
    }

    @TestCase
    func testAuthenticationGSSContinue(): Unit {
        let proto = AuthenticationGSSContinue()
                
        proto.toString()
    
        let deserialize_proto = AuthenticationGSSContinue.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.code.value() == proto.code.value())
        @Assert(deserialize_proto.data.size == proto.data.size)

        var decode_proto = AuthenticationGSSContinue()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.code.value() == proto.code.value())
        @Assert(decode_proto.data.size == proto.data.size)        
    }

    @TestCase
    func testAuthenticationGSS(): Unit {
        let proto = AuthenticationGSS()
        
        proto.toString()

        let deserialize_proto = AuthenticationGSS.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.code.value() == proto.code.value())

        var decode_proto = AuthenticationGSS()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.code.value() == proto.code.value())        
    }

    @TestCase
    func testAuthenticationKerberosV5(): Unit {
        let proto = AuthenticationKerberosV5()
        
        proto.toString()

        let deserialize_proto = AuthenticationKerberosV5.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.code.value() == proto.code.value())

        var decode_proto = AuthenticationKerberosV5()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.code.value() == proto.code.value())        
    }

    @TestCase
    func testAuthenticationMD5Password(): Unit {
        let proto = AuthenticationMD5Password()
        
        proto.toString()

        let deserialize_proto = AuthenticationMD5Password.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.code.value() == proto.code.value())
        @Assert(deserialize_proto.data.size == proto.data.size)

        var decode_proto = AuthenticationMD5Password()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.code.value() == proto.code.value())
        @Assert(decode_proto.data.size == proto.data.size)        
    }

    @TestCase
    func testAuthenticationOk(): Unit {
        let proto = AuthenticationOk()
        
        proto.toString()

        let deserialize_proto = AuthenticationOk.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.code.value() == proto.code.value())

        var decode_proto = AuthenticationOk()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.code.value() == proto.code.value())        
    }

    @TestCase
    func testAuthenticationRFC5802(): Unit {
        let proto = AuthenticationRFC5802()
        
        let ret = proto.toString()

        let deserialize_proto = AuthenticationRFC5802.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.code.value() == proto.code.value())
        @Assert(deserialize_proto.pwdMethod == proto.pwdMethod)
        @Assert(deserialize_proto.rnd64.size == proto.rnd64.size)
        @Assert(deserialize_proto.serverSignature.size == proto.serverSignature.size)
        @Assert(deserialize_proto.token.size == proto.token.size)
        @Assert(deserialize_proto.iterstep == proto.iterstep)
        @Assert(deserialize_proto.data.size == proto.data.size)

        var decode_proto = AuthenticationRFC5802()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.code.value() == proto.code.value())
        @Assert(decode_proto.pwdMethod == proto.pwdMethod)
        @Assert(decode_proto.rnd64.size == proto.rnd64.size)
        @Assert(decode_proto.serverSignature.size == proto.serverSignature.size)
        @Assert(decode_proto.token.size == proto.token.size)
        @Assert(decode_proto.iterstep == proto.iterstep)
        @Assert(decode_proto.data.size == proto.data.size)       
    }

    @TestCase
    func testAuthenticationSASLContinue(): Unit {
        let proto = AuthenticationSASLContinue()
        
        proto.toString()

        let deserialize_proto = AuthenticationSASLContinue.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.code.value() == proto.code.value())
        @Assert(deserialize_proto.data.size == proto.data.size)     

        var decode_proto = AuthenticationSASLContinue()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.code.value() == proto.code.value())
        @Assert(decode_proto.data.size == proto.data.size)         
    }

    @TestCase
    func testAuthenticationSASLFinal(): Unit {
        let proto = AuthenticationSASLFinal()
        
        proto.toString()

        let deserialize_proto = AuthenticationSASLFinal.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.code.value() == proto.code.value())
        @Assert(deserialize_proto.data.size == proto.data.size)     

        var decode_proto = AuthenticationSASLFinal()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.code.value() == proto.code.value())
        @Assert(decode_proto.data.size == proto.data.size)          
    }

    @TestCase
    func testAuthenticationSASL(): Unit {
        let proto = AuthenticationSASL()
        
        proto.toString()

        let deserialize_proto = AuthenticationSASL.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.code.value() == proto.code.value())
        @Assert(deserialize_proto.mechanisms.size == proto.mechanisms.size)     

        var decode_proto = AuthenticationSASL()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.code.value() == proto.code.value())
        @Assert(decode_proto.mechanisms.size == proto.mechanisms.size)         
    }

    @TestCase
    func testAuthenticationSCMCredential(): Unit {
        let proto = AuthenticationSCMCredential()
        
        proto.toString()

        let deserialize_proto = AuthenticationSCMCredential.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.code.value() == proto.code.value())

        var decode_proto = AuthenticationSCMCredential()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.code.value() == proto.code.value())       
    }

    @TestCase
    func testAuthenticationSSPI(): Unit {
        let proto = AuthenticationSSPI()
        
        proto.toString()

        let deserialize_proto = AuthenticationSSPI.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.code.value() == proto.code.value())

        var decode_proto = AuthenticationSSPI()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.code.value() == proto.code.value())       
    }

    @TestCase
    func testBackendKeyData(): Unit {
        let proto = BackendKeyData()
        
        proto.toString()

        let deserialize_proto = BackendKeyData.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            
        @Assert(deserialize_proto.processID == proto.processID)
        @Assert(deserialize_proto.secretkey == proto.secretkey)

        var decode_proto = BackendKeyData()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)            
        @Assert(decode_proto.processID == proto.processID)
        @Assert(decode_proto.secretkey == proto.secretkey)        
    }

    @TestCase
    func testBindComplete(): Unit {
        let proto = BindComplete()
        
        proto.toString()

        let deserialize_proto = BindComplete.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)            

        var decode_proto = BindComplete()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)
    }

    @TestCase
    func testBind(): Unit {
        let proto = Bind()
        
        proto.toString()

        let deserialize_proto = Bind.deserialize(proto.serialize())
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.dstPortalName == proto.dstPortalName)
        @Assert(deserialize_proto.srcPrepStmtName == proto.srcPrepStmtName)
        @Assert(deserialize_proto.paramFmtNum == proto.paramFmtNum)
        @Assert(deserialize_proto.paramFmts.size == proto.paramFmts.size)
        @Assert(deserialize_proto.paramValNum == proto.paramValNum)
        @Assert(deserialize_proto.params.size == proto.params.size)
        @Assert(deserialize_proto.resultFmtNum == proto.resultFmtNum)
        @Assert(deserialize_proto.resultFmts.size == proto.resultFmts.size)

        var decode_proto = Bind()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.len == proto.len)    
        @Assert(decode_proto.dstPortalName == proto.dstPortalName)
        @Assert(decode_proto.srcPrepStmtName == proto.srcPrepStmtName)
        @Assert(decode_proto.paramFmtNum == proto.paramFmtNum)
        @Assert(decode_proto.paramFmts.size == proto.paramFmts.size)
        @Assert(decode_proto.paramValNum == proto.paramValNum)
        @Assert(decode_proto.params.size == proto.params.size)
        @Assert(decode_proto.resultFmtNum == proto.resultFmtNum)
        @Assert(decode_proto.resultFmts.size == proto.resultFmts.size)  
    }

    @TestCase
    func testCancelRequest(): Unit {
        let proto = CancelRequest()
        
        proto.toString()

        let deserialize_proto = CancelRequest.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.reqCode == proto.reqCode)
        @Assert(deserialize_proto.processID == proto.processID)
        @Assert(deserialize_proto.secretkey == proto.secretkey)    

        var decode_proto = CancelRequest()
        decode_proto.decode(proto.encode()[4..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.reqCode == proto.reqCode)
        @Assert(decode_proto.processID == proto.processID)
        @Assert(decode_proto.secretkey == proto.secretkey)  
    }

    @TestCase
    func testCloseComplete(): Unit {
        let proto = CloseComplete()
        
        proto.toString()

        let deserialize_proto = CloseComplete.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)

        var decode_proto = CloseComplete()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)   
    }

    @TestCase
    func testClose(): Unit {
        let proto = Close()
        
        proto.toString()

        let deserialize_proto = Close.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.describe == proto.describe)
        @Assert(deserialize_proto.name == proto.name)

        var decode_proto = Close()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)    
        @Assert(decode_proto.describe == proto.describe)
        @Assert(decode_proto.name == proto.name)    
    }

    @TestCase
    func testCommandComplete(): Unit {
        let proto = CommandComplete()
        
        proto.toString()

        let deserialize_proto = CommandComplete.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.commandTag == proto.commandTag)

        var decode_proto = CommandComplete()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)    
        @Assert(decode_proto.commandTag == proto.commandTag)
    }

    @TestCase
    func testCopyBothResponse(): Unit {
        let proto = CopyBothResponse()
        
        proto.toString()

        let deserialize_proto = CopyBothResponse.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.overallFmt == proto.overallFmt)
        @Assert(deserialize_proto.colNum == proto.colNum)
        @Assert(deserialize_proto.colFmts == proto.colFmts)

        var decode_proto = CopyBothResponse()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)    
        @Assert(decode_proto.overallFmt == proto.overallFmt)
        @Assert(decode_proto.colNum == proto.colNum)
        @Assert(decode_proto.colFmts == proto.colFmts)
    }

    @TestCase
    func testCopyData(): Unit {
        let proto = CopyData()
        
        proto.toString()

        let deserialize_proto = CopyData.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.data.size == proto.data.size)

        var decode_proto = CopyData()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)    
        @Assert(decode_proto.data.size == proto.data.size)
    }

    @TestCase
    func testCopyDone(): Unit {
        let proto = CopyDone()
        
        proto.toString()

        let deserialize_proto = CopyDone.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)

        var decode_proto = CopyDone()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
    }

    @TestCase
    func testCopyFail(): Unit {
        let proto = CopyFail()
        
        proto.toString()

        let deserialize_proto = CopyFail.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.errorMsg == proto.errorMsg)

        var decode_proto = CopyFail()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.errorMsg == proto.errorMsg)
    }

    @TestCase
    func testCopyInResponse(): Unit {
        let proto = CopyInResponse()
        
        proto.toString()

        let deserialize_proto = CopyInResponse.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.overallFmt == proto.overallFmt)
        @Assert(deserialize_proto.colNum == proto.colNum)
        @Assert(deserialize_proto.colFmts.size == proto.colFmts.size)

        var decode_proto = CopyInResponse()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.overallFmt == proto.overallFmt)
        @Assert(decode_proto.colNum == proto.colNum)
        @Assert(decode_proto.colFmts.size == proto.colFmts.size)
    }

    @TestCase
    func testCopyOutResponse(): Unit {
        let proto = CopyOutResponse()
        
        proto.toString()

        let deserialize_proto = CopyOutResponse.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.overallFmt == proto.overallFmt)
        @Assert(deserialize_proto.colNum == proto.colNum)
        @Assert(deserialize_proto.colFmts.size == proto.colFmts.size)

        var decode_proto = CopyOutResponse()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.overallFmt == proto.overallFmt)
        @Assert(decode_proto.colNum == proto.colNum)
        @Assert(decode_proto.colFmts.size == proto.colFmts.size)
    }

    @TestCase
    func testDataRow(): Unit {
        let proto = DataRow()
        
        proto.toString()

        let deserialize_proto = DataRow.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.fieldNum == proto.fieldNum)
        @Assert(deserialize_proto.fields.size == proto.fields.size)

        var decode_proto = DataRow()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.fieldNum == proto.fieldNum)
        @Assert(decode_proto.fields.size == proto.fields.size)
    }

    @TestCase
    func testDescribe(): Unit {
        let proto = Describe()
       
        proto.toString()

        let deserialize_proto = Describe.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.describe == proto.describe)
        @Assert(deserialize_proto.name == proto.name)

        var decode_proto = Describe()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.describe == proto.describe)
        @Assert(decode_proto.name == proto.name)
    }

    @TestCase
    func testEmptyQueryResponse(): Unit {
        let proto = EmptyQueryResponse()
        
        proto.toString()

        let deserialize_proto = EmptyQueryResponse.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)

        var decode_proto = EmptyQueryResponse()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
    }

    @TestCase
    func testErrorResponse(): Unit {
        let proto = ErrorResponse()
        
        proto.toString()

        let deserialize_proto = ErrorResponse.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.params.size == proto.params.size)

        var decode_proto = ErrorResponse()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.params.size == proto.params.size)
    }

    @TestCase
    func testExecute(): Unit {
        let proto = Execute()
        
        proto.toString()

        let deserialize_proto = Execute.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.portalName == proto.portalName)
        @Assert(deserialize_proto.maxRowNum == proto.maxRowNum)

        var decode_proto = Execute()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.portalName == proto.portalName)
        @Assert(decode_proto.maxRowNum == proto.maxRowNum)
    }

    @TestCase
    func testFlush(): Unit {
        let proto = Flush()
        
        proto.toString()

        let deserialize_proto = Flush.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)

        var decode_proto = Flush()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
    }

    @TestCase
    func testFunctionCallResponse(): Unit {
        let proto = FunctionCallResponse()
        
        proto.toString()

        let deserialize_proto = FunctionCallResponse.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.resultLen == proto.resultLen)
        @Assert(deserialize_proto.result.size == proto.result.size)

        var decode_proto = FunctionCallResponse()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.resultLen == proto.resultLen)
        @Assert(decode_proto.result.size == proto.result.size)
    }

    @TestCase
    func testFunctionCall(): Unit {
        let arg = FunctionArgument()        
        var proto = FunctionCall()
        proto.args.add(arg)
        proto.argNum = 1
        FunctionArgument.deserialize(arg.serialize())
        
        proto.toString()
        let deserialize_proto = FunctionCall.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.funcOid == proto.funcOid)
        @Assert(deserialize_proto.argFmtNum == proto.argFmtNum)
        @Assert(deserialize_proto.argFmts.size == proto.argFmts.size)
        @Assert(deserialize_proto.argNum == proto.argNum)
        @Assert(deserialize_proto.args.size == proto.args.size)
        @Assert(deserialize_proto.resultFmt == proto.resultFmt)

        var decode_proto = FunctionCall()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.funcOid == proto.funcOid)
        @Assert(decode_proto.argFmtNum == proto.argFmtNum)
        @Assert(decode_proto.argFmts.size == proto.argFmts.size)
        @Assert(decode_proto.argNum == proto.argNum)
        @Assert(decode_proto.args.size == proto.args.size)
        @Assert(decode_proto.resultFmt == proto.resultFmt)
    }

    @TestCase
    func testGSSENCRequest(): Unit {
        let proto = GSSENCRequest()
        
        proto.toString()

        let deserialize_proto = GSSENCRequest.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.reqCode == proto.reqCode)

        var decode_proto = GSSENCRequest()
        decode_proto.decode(proto.encode()[4..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.reqCode == proto.reqCode)
    }

    @TestCase
    func testGSSResponse(): Unit {
        let proto = GSSResponse()
        
        proto.toString()

        let deserialize_proto = GSSResponse.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.data.size == proto.data.size)

        var decode_proto = GSSResponse()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.data.size == proto.data.size)
    }

    @TestCase
    func testNegotiateProtocolVersion(): Unit {
        let proto = NegotiateProtocolVersion()
        
        proto.toString()

        let deserialize_proto = NegotiateProtocolVersion.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.minorProtoVersion == proto.minorProtoVersion)
        @Assert(deserialize_proto.unknownOptNum == proto.unknownOptNum)
        @Assert(deserialize_proto.optionName == proto.optionName)

        var decode_proto = NegotiateProtocolVersion()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.minorProtoVersion == proto.minorProtoVersion)
        @Assert(decode_proto.unknownOptNum == proto.unknownOptNum)
        @Assert(decode_proto.optionName == proto.optionName)
    }

    @TestCase
    func testNoData(): Unit {
        let proto = NoData()
        
        proto.toString()

        let deserialize_proto = NoData.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)

        var decode_proto = NoData()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
    }

    @TestCase
    func testNoticeResponse(): Unit {
        let proto = NoticeResponse()
        
        proto.toString()

        let deserialize_proto = NoticeResponse.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.params.size == proto.params.size)

        var decode_proto = NoticeResponse()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.params.size == proto.params.size)
    }

    @TestCase
    func testNotificationResponse(): Unit {
        let proto = NotificationResponse()
        
        proto.toString()

        let deserialize_proto = NotificationResponse.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.processID == proto.processID)
        @Assert(deserialize_proto.channelName == proto.channelName)
        @Assert(deserialize_proto.payload == proto.payload)

        var decode_proto = NotificationResponse()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.processID == proto.processID)
        @Assert(decode_proto.channelName == proto.channelName)
        @Assert(decode_proto.payload == proto.payload)
    }

    @TestCase
    func testParameterDescription(): Unit {
        let proto = ParameterDescription()
        
        proto.toString()

        let deserialize_proto = ParameterDescription.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.paramNum == proto.paramNum)
        @Assert(deserialize_proto.paramOids.size == proto.paramOids.size)

        var decode_proto = ParameterDescription()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.paramNum == proto.paramNum)
        @Assert(decode_proto.paramOids.size == proto.paramOids.size)
    }

    @TestCase
    func testParameterStatus(): Unit {
        let proto = ParameterStatus()
        
        proto.toString()

        let deserialize_proto = ParameterStatus.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.paramName == proto.paramName)
        @Assert(deserialize_proto.paramValue == proto.paramValue)

        var decode_proto = ParameterStatus()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(deserialize_proto.paramName == proto.paramName)
        @Assert(deserialize_proto.paramValue == proto.paramValue)
    }

    @TestCase
    func testParseComplete(): Unit {
        let proto = ParseComplete()
        
        proto.toString()

        let deserialize_proto = ParseComplete.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)

        var decode_proto = ParseComplete()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
    }

    @TestCase
    func testParse(): Unit {
        let proto = Parse()
        
        proto.toString()

        let deserialize_proto = Parse.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.name == proto.name)
        @Assert(deserialize_proto.query == proto.query)
        @Assert(deserialize_proto.paramNum == proto.paramNum)
        @Assert(deserialize_proto.datatypeOids.size == proto.datatypeOids.size)

        var decode_proto = Parse()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.name == proto.name)
        @Assert(decode_proto.query == proto.query)
        @Assert(decode_proto.paramNum == proto.paramNum)
        @Assert(decode_proto.datatypeOids.size == proto.datatypeOids.size)
    }

    @TestCase
    func testPasswordMessage(): Unit {
        let proto = PasswordMessage()
        
        proto.toString()

        let deserialize_proto = PasswordMessage.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.password == proto.password)

        var decode_proto = PasswordMessage()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(deserialize_proto.password == proto.password)
    }

    @TestCase
    func testPortalSuspended(): Unit {
        let proto = PortalSuspended()
        
        proto.toString()

        let deserialize_proto = PortalSuspended.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)

        var decode_proto = PortalSuspended()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
    }

    @TestCase
    func testQuery(): Unit {
        let proto = Query()
        
        proto.toString()

        let deserialize_proto = Query.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.query == proto.query)

        var decode_proto = Query()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.query == proto.query)
    }

    @TestCase
    func testReadyForQuery(): Unit {
        let proto = ReadyForQuery()
        
        proto.toString()

        let deserialize_proto = ReadyForQuery.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.status == proto.status)

        var decode_proto = ReadyForQuery()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.status == proto.status)
    }

    @TestCase
    func testFieldDescription(): Unit {
        let proto = FieldDescription()
        
        proto.toString()

        let deserialize_proto = FieldDescription.deserialize(proto.serialize())
        @Assert(deserialize_proto.name == proto.name)
        @Assert(deserialize_proto.tblOid == proto.tblOid)
        @Assert(deserialize_proto.tblAttrNum == proto.tblAttrNum)
        @Assert(deserialize_proto.datatypeOid == proto.datatypeOid)
        @Assert(deserialize_proto.datatypeLen == proto.datatypeLen)
        @Assert(deserialize_proto.typeModifier == proto.typeModifier)
        @Assert(deserialize_proto.fmtCode == proto.fmtCode)

        var decode_proto = FieldDescription()
        let write_buff = ReadWriteBuffer()        
        proto.encode(write_buff)
        
        let read_buff = ReadOnlyBuffer(write_buff.data())
        decode_proto.decode(read_buff)
        @Assert(decode_proto.name == proto.name)
        @Assert(decode_proto.tblOid == proto.tblOid)
        @Assert(decode_proto.tblAttrNum == proto.tblAttrNum)
        @Assert(decode_proto.datatypeOid == proto.datatypeOid)
        @Assert(decode_proto.datatypeLen == proto.datatypeLen)
        @Assert(decode_proto.typeModifier == proto.typeModifier)
        @Assert(decode_proto.fmtCode == proto.fmtCode)
    }

    @TestCase
    func testRowDescription(): Unit {
        let proto = RowDescription()
        
        proto.toString()

        let deserialize_proto = RowDescription.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.fieldNum == proto.fieldNum)
        @Assert(deserialize_proto.fields.size == proto.fields.size)

        var decode_proto = RowDescription()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.fieldNum == proto.fieldNum)
        @Assert(decode_proto.fields.size == proto.fields.size)
    }

    @TestCase
    func testSASLInitialResponse(): Unit {
        let proto = SASLInitialResponse()
        
        proto.toString()

        let deserialize_proto = SASLInitialResponse.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.name == proto.name)
        @Assert(deserialize_proto.datalen == proto.datalen)
        @Assert(deserialize_proto.data.size == proto.data.size)

        var decode_proto = SASLInitialResponse()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.name == proto.name)
        @Assert(decode_proto.datalen == proto.datalen)
        @Assert(decode_proto.data.size == proto.data.size)
    }

    @TestCase
    func testSASLResponse(): Unit {
        let proto = SASLResponse()
        
        proto.toString()

        let deserialize_proto = SASLResponse.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)
        @Assert(deserialize_proto.data.size == proto.data.size)

        var decode_proto = SASLResponse()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
        @Assert(decode_proto.data.size == proto.data.size)
    }

    @TestCase
    func testSSLRequest(): Unit {
        let proto = SSLRequest()
    
        proto.toString()

        let deserialize_proto = SSLRequest.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.reqCode == proto.reqCode)

        var decode_proto = SSLRequest()
        decode_proto.decode(proto.encode()[4..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.reqCode == proto.reqCode)
    }

    @TestCase
    func testStartupMessage(): Unit {
        let proto = StartupMessage()
        
        proto.toString()

        let deserialize_proto = StartupMessage.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.protocolVersion == proto.protocolVersion)
        @Assert(deserialize_proto.parameters.size == proto.parameters.size)

        var decode_proto = StartupMessage()
        decode_proto.decode(proto.encode()[4..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.protocolVersion == proto.protocolVersion)
        @Assert(decode_proto.parameters.size == proto.parameters.size)
    }

    @TestCase
    func testSync(): Unit {
        let proto = Sync()
        
        proto.toString()

        let deserialize_proto = Sync.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)

        var decode_proto = Sync()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
    }

    @TestCase
    func testTerminate(): Unit {
        let proto = Terminate()
    
        proto.toString()

        let deserialize_proto = Terminate.deserialize(proto.serialize())
        @Assert(deserialize_proto.len == proto.len)
        @Assert(deserialize_proto.kind == proto.kind)

        var decode_proto = Terminate()
        decode_proto.decode(proto.encode()[5..])
        @Assert(decode_proto.len == proto.len)
        @Assert(decode_proto.kind == proto.kind)
    }

    @TestCase
    func testProto3(): Unit {
        try
        {
            // CloseComplete
            let req = ParseComplete()
            var input = ByteBuffer(req.encode())
            var input_stream = BufferedInputStream(input)
            var output = ByteBuffer()
            var output_stream = BufferedOutputStream(output)
            var backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // NotificationResponse
            let req1 = NotificationResponse()
            input = ByteBuffer(req1.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // CopyDone
            let req2 = CopyDone()
            input = ByteBuffer(req2.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // CopyData
            let req3 = CopyData()
            input = ByteBuffer(req3.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // CopyInResponse
            let req4 = CopyInResponse()
            input = ByteBuffer(req4.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // CopyOutResponse
            let req5 = CopyOutResponse()
            input = ByteBuffer(req5.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // EmptyQueryResponse
            let req6 = EmptyQueryResponse()
            input = ByteBuffer(req6.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // NoticeResponse
            let req7 = NoticeResponse()
            input = ByteBuffer(req7.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // PortalSuspended
            let req8 = PortalSuspended()
            input = ByteBuffer(req8.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // ParameterDescription
            let req9 = ParameterDescription()
            input = ByteBuffer(req9.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // NegotiateProtocolVersion
            let req10 = NegotiateProtocolVersion()
            input = ByteBuffer(req10.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // FunctionCallResponse
            let req11 = FunctionCallResponse()
            input = ByteBuffer(req11.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // CopyBothResponse
            let req12 = CopyBothResponse()
            input = ByteBuffer(req12.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // AuthenticationKerberosV5
            let req13 = AuthenticationKerberosV5()
            input = ByteBuffer(req13.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // AuthenticationCleartextPassword
            let req14 = AuthenticationCleartextPassword()
            input = ByteBuffer(req14.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // AuthenticationMD5Password
            let req15 = AuthenticationMD5Password()
            input = ByteBuffer(req15.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // AuthenticationSCMCredential
            let req16 = AuthenticationSCMCredential()
            input = ByteBuffer(req16.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // AuthenticationGSS
            let req17 = AuthenticationGSS()
            input = ByteBuffer(req17.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // AuthenticationGSSContinue
            let req18 = AuthenticationGSSContinue()
            input = ByteBuffer(req18.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // AuthenticationSSPI
            let req19 = AuthenticationSSPI()
            input = ByteBuffer(req19.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.OpenGauss).getOrThrow()

            // AuthenticationSASLContinue
            let req21 = AuthenticationSASLContinue()
            input = ByteBuffer(req21.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.Postgres).getOrThrow()

            // AuthenticationSASLContinue
            let req22 = AuthenticationSASLContinue()
            input = ByteBuffer(req22.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.Postgres).getOrThrow()

            // AuthenticationSASL
            let req23 = AuthenticationSASL()
            input = ByteBuffer(req23.encode())
            input_stream = BufferedInputStream(input)
            output = ByteBuffer()
            output_stream = BufferedOutputStream(output)
            backend = Frontend(input_stream, output_stream)
            backend.receive(DBType.Postgres).getOrThrow()

            @Assert(DBType.Postgres == DBType.of(2))
            @Assert(DBType.OpenGauss == DBType.of(1))
            @Assert(DBType.Family == DBType.of(0))
            @Assert(0 == DBType.of(0).value())
            @Assert(DBType.of(1) != DBType.of(0))
            DBType.of(1).toString()
        } catch (ex: Exception) {
            ex.printStackTrace()
            @Assert(false)
        }
    }

}



