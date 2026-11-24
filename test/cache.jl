module CacheLifetimeTests
using TurboDispatch, Test
using TurboDispatch: TaggedArg, family, discover!, register!, registermember!, registerfunction!, refresh!, dispatch, typeid, backend

struct Payload; n::Int; end
@noinline function temporaryregistration()
    state=[3]
    f=x->x.n+state[1]
    run=registerfunction!(f,Payload)
    @test registerfunction!(f,Payload)===run
    @test run(Payload(2))==5
    WeakRef(run),WeakRef(state)
end
@testset "registration cache releases unused closures" begin
    run,state=temporaryregistration()
    GC.gc(true); GC.gc(true)
    @test run.value===nothing
    @test state.value===nothing
end
end
