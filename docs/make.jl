using Documenter, TurboDispatch

makedocs(
    sitename="TurboDispatch.jl",
    modules=[TurboDispatch],
    remotes=nothing,
    format=Documenter.HTML(
        prettyurls=get(ENV,"CI","false")=="true",
        edit_link="main",
        assets=["assets/logo.css"],
        repolink="https://github.com/Ntropic/TurboDispatch.jl",
    ),
    pages=["Overview"=>"index.md", "User Guide"=>"examples.md", "API reference"=>"api.md", "Benchmarks"=>"benchmarks.md"],
    checkdocs=:exports,
)

if get(ENV,"GITHUB_ACTIONS","false")=="true" && get(ENV,"GITHUB_EVENT_NAME","")!="pull_request"
    deploydocs(repo="github.com/Ntropic/TurboDispatch.jl.git",devbranch="main")
end
