module HotOrderingTests
using TurboDispatch, Test
using TurboDispatch: tagvalue, TaggedArg, family, discover!, register!, registermember!, registerfunction!, refresh!, dispatch, typeid, backend

abstract type Root end
abstract type Group <: Root end
struct A <: Group; n::Int; end
struct B <: Group; n::Int; end
struct E <: Group; n::Int; end
struct G <: Group; n::Int; end
struct C <: Root; n::Int; end
struct D <: Root; n::Int; end
struct F <: Root; n::Int; end
score(x)=x.n+1
pair(x,y)=10x.n+y.n
unblock(x)=x isa Expr && x.head==:block ? unblock(last(x.args)) : x

@testset "direct hot checks and abstract subtrees" begin
    f=family(Root;discover=false)
    for T in (C,A,D,B,E,F,G); register!(Root,T); end
    ids=map(T->typeid(f,T),(C,A,D,B,E,F,G))
    plain=registerfunction!(score,Root)
    family(Root;order=(C,))
    prioritized=registerfunction!(score,Root)
    @test plain !== prioritized # Same leaf order, different tree shape.
    family(Root;order=(F,Group))
    @test TurboDispatch.familyhotgroups(f)==((6,),(2,4,5,7))
    for mode in (:eager,:lazy)
        run=registerfunction!(score,Root;compilation=mode,return_type=Int)
        both=registerfunction!(pair,Root,Root;compilation=mode,return_type=Int)
        for (i,T) in enumerate((C,A,D,B,E,F,G))
            x=T(i)
            @test run(x)==score(x)
            @test run(tagvalue(x,f))==score(x)
            for (j,U) in enumerate((C,A,D,B,E,F,G))
                @test both(x,U(j))==pair(x,U(j))
            end
        end
        K=typeof(run).parameters[3]
        body=TurboDispatch.branchcode(K.parameters...,1,Any[TurboDispatch.signaturetypes(K.parameters[1])...],1)
        @test body.head==:if
        @test body.args[1]==:(tags[1]==$(UInt(6)))
        group=unblock(body.args[3])
        @test group.head==:if
        subtree=unblock(group.args[2])
        @test subtree.head==:if
        @test unblock(subtree.args[2]).head==:if
        @test unblock(subtree.args[3]).head==:if
        family(Root;order=(Group,A))
        @test TurboDispatch.familyhotgroups(f)==((2,4,5,7),)
        @test run(F(9))==10 # Existing handles retain their tree.
        @test refresh!(run)(A(8))==9
        family(Root;order=(F,Group))
    end
    family(Root;order=(A,Group,A,C,D,F))
    @test TurboDispatch.familyhotgroups(f)==((2,),(4,5,7),(1,),(3,),(6,))
    allhot=registerfunction!(score,Root)
    @test allhot(G(3))==4
    family(Root;order=())
    @test isempty(TurboDispatch.familyhotgroups(f))
    @test map(T->typeid(f,T),(C,A,D,B,E,F,G))==ids
    @test registerfunction!(score,Root)===plain
end
end
