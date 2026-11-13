using Blog.Infra;

return await Pulumi.Deployment.RunAsync<BlogInfrastructure>();
