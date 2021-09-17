﻿using System.Collections.Generic;
using FluentAssertions;
using LinkDotNet.Blog.Web;
using Microsoft.Extensions.Configuration;
using Xunit;

namespace LinkDotNet.Blog.UnitTests.Web
{
    public class AppConfigurationFactoryTests
    {
        [Fact]
        public void ShouldMapFromAppConfiguration()
        {
            var inMemorySettings = new Dictionary<string, string>
            {
                { "BlogName", "UnitTest" },
                { "GithubAccountUrl", "github" },
                { "LinkedInAccountUrl", "linkedIn" },
                { "ConnectionString", "cs" },
                { "DatabaseName", "db" },
                { "Introduction:BackgroundUrl", "someurl" },
                { "Introduction:ProfilePictureUrl", "anotherurl" },
                { "Introduction:Description", "desc" },
                { "BlogPostsPerPage", "5" },
                { "AboutMeProfileInformation:Name", "Steven" },
                { "AboutMeProfileInformation:Heading", "Dev" },
                { "AboutMeProfileInformation:ProfilePictureUrl", "Url" },
            };
            var configuration = new ConfigurationBuilder()
                .AddInMemoryCollection(inMemorySettings)
                .Build();

            var appConfiguration = AppConfigurationFactory.Create(configuration);

            appConfiguration.BlogName.Should().Be("UnitTest");
            appConfiguration.GithubAccountUrl.Should().Be("github");
            appConfiguration.HasGithubAccount.Should().BeTrue();
            appConfiguration.LinkedinAccountUrl.Should().Be("linkedIn");
            appConfiguration.HasLinkedinAccount.Should().BeTrue();
            appConfiguration.ConnectionString.Should().Be("cs");
            appConfiguration.DatabaseName.Should().Be("db");
            appConfiguration.Introduction.BackgroundUrl.Should().Be("someurl");
            appConfiguration.Introduction.ProfilePictureUrl.Should().Be("anotherurl");
            appConfiguration.Introduction.Description.Should().Be("desc");
            appConfiguration.BlogPostsPerPage.Should().Be(5);
            appConfiguration.IsAboutMeEnabled.Should().BeTrue();
            appConfiguration.ProfileInformation.Name.Should().Be("Steven");
            appConfiguration.ProfileInformation.Heading.Should().Be("Dev");
            appConfiguration.ProfileInformation.ProfilePictureUrl.Should().Be("Url");
        }

        [Theory]
        [InlineData(null, null, false, false)]
        [InlineData(null, "linkedin", false, true)]
        [InlineData("github", null, true, false)]
        public void ShouldSetGithubLinkedAccountAccordingToValueSet(
            string githubUrl,
            string linkedInUrl,
            bool githubAvailable,
            bool linkedInAvailable)
        {
            var inMemorySettings = new Dictionary<string, string>
            {
                { "Introduction:BackgroundUrl", "someurl" },
                { "Introduction:ProfilePictureUrl", "anotherurl" },
                { "Introduction:Description", "desc" },
                { "GithubAccountUrl", githubUrl },
                { "LinkedInAccountUrl", linkedInUrl },
                { "BlogPostsPerPage", "2" },
            };
            var configuration = new ConfigurationBuilder()
                .AddInMemoryCollection(inMemorySettings)
                .Build();

            var appConfiguration = AppConfigurationFactory.Create(configuration);

            appConfiguration.HasGithubAccount.Should().Be(githubAvailable);
            appConfiguration.HasLinkedinAccount.Should().Be(linkedInAvailable);
        }

        [Fact]
        public void ShouldSetIsAboutMeEnabledToFalseWhenNoInformation()
        {
            var inMemorySettings = new Dictionary<string, string>
            {
                { "Introduction:BackgroundUrl", "someurl" },
                { "Introduction:ProfilePictureUrl", "anotherurl" },
                { "Introduction:Description", "desc" },
                { "BlogPostsPerPage", "2" },
            };
            var configuration = new ConfigurationBuilder()
                .AddInMemoryCollection(inMemorySettings)
                .Build();

            var appConfiguration = AppConfigurationFactory.Create(configuration);

            appConfiguration.IsAboutMeEnabled.Should().BeFalse();
        }
    }
}